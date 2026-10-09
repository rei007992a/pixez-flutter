import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

class GeminiTranslator {
  static const String _prefKey = 'gemini_api_key';
  static final Dio _dio = Dio();

  /// 保存されているGemini APIキーを取得
  static Future<String?> getApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefKey);
  }

  /// Gemini APIキーを保存
  static Future<void> saveApiKey(String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, apiKey.trim());
  }

  /// 中国語官能小説の翻訳プロンプト
  static const String _systemInstruction = '''
あなたは中国語の官能小説・成年向けWeb小説（TL/BL/エロノベル等）の専門翻訳家です。
以下の中国語の小説テキストを、最高品質かつ艶やかで情緒ある日本語の官能小説に翻訳してください。

【翻訳の鉄則】
1. 官能描写・淫語・喘ぎ声・擬音の翻案:
   - 息遣いや喘ぎ声（「嗯…」「啊…」「哈啊…」「唔…」など）は日本の官能小説らしく「んっ…」「あぁっ…」「ふーっ…」「ひゃぅ…」等に自然に翻案してください。
   - 官能用語・淫語（肉棒、花穴、淫水、后穴、高潮、粗暴など）は、文脈に応じた日本の成人向け小説らしい艶やかで刺激的な言葉遣いに翻訳してください。
2. 中国ネット検閲回避の伏字・ピンイン略語の解読:
   - 「jb（肉棒/阴茎）」「ml（性行為/make love）」「xxoo（性行為）」「ghs（搞黄色/エロ）」「dbq（対不起）」「nsdd（你说得对）」などのスラング・頭文字略語や記号伏字（〇〇、**等）を正しく文脈から解読して自然な日本語に直してください。
3. 文体と語り口:
   - 直訳調（機械翻訳調）は避け、日本語の小説として自然で読みやすく、読者の五感を刺激する文章にしてください。
   - 一人称や二人称、登場人物の口調のブレをなくしてください。
4. 原文に含まれるPixiv小説制御タグ（例: [[rb:漢字>ルビ]], [[jump:...]], [newpage]）はそのまま保持してください。
5. 余計な前置きや解説、挨拶（「はい、翻訳しました」等）は一切出力せず、翻訳した小説本文のみを出力してください。
''';

  /// 小説本文を翻訳する
  /// 長文の場合は段落ごとに分割して順次翻訳
  static Future<String> translateNovel(
    String rawText, {
    void Function(double progress, String status)? onProgress,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw Exception('Gemini APIキーが設定されていません。');
    }

    // 長文分割（約2500文字区切りを目安に改行位置で分割）
    final chunks = _splitIntoChunks(rawText, maxChunkSize: 2500);
    final translatedChunks = <String>[];

    for (int i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      if (onProgress != null) {
        final progress = (i + 1) / chunks.length;
        onProgress(progress, '翻訳中 (${i + 1}/${chunks.length})...');
      }

      final translated = await _translateChunk(chunk, apiKey.trim());
      translatedChunks.add(translated);
    }

    return translatedChunks.join('\n\n');
  }

  /// 1チャンクをGemini APIに送信して翻訳
  static Future<String> _translateChunk(String chunk, String apiKey) async {
    // gemini-2.0-flash または gemini-1.5-flash
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$apiKey';

    final requestBody = {
      "contents": [
        {
          "role": "user",
          "parts": [
            {
              "text":
                  "$_systemInstruction\n\n【以下の中国語小説テキストを日本語に翻訳してください】\n$chunk"
            }
          ]
        }
      ],
      "generationConfig": {
        "temperature": 0.4,
        "maxOutputTokens": 8192,
      },
      // セーフティフィルターをすべて完全無効化（官能描写をブロックさせない）
      "safetySettings": [
        {
          "category": "HARM_CATEGORY_HARASSMENT",
          "threshold": "BLOCK_NONE"
        },
        {
          "category": "HARM_CATEGORY_HATE_SPEECH",
          "threshold": "BLOCK_NONE"
        },
        {
          "category": "HARM_CATEGORY_SEXUALLY_EXPLICIT",
          "threshold": "BLOCK_NONE"
        },
        {
          "category": "HARM_CATEGORY_DANGEROUS_CONTENT",
          "threshold": "BLOCK_NONE"
        }
      ]
    };

    try {
      final response = await _dio.post(
        url,
        data: requestBody,
        options: Options(
          headers: {'Content-Type': 'application/json'},
          sendTimeout: const Duration(seconds: 40),
          receiveTimeout: const Duration(seconds: 60),
        ),
      );

      if (response.statusCode == 200) {
        final data = response.data;
        final candidates = data['candidates'] as List?;
        if (candidates != null && candidates.isNotEmpty) {
          final content = candidates[0]['content'];
          final parts = content['parts'] as List?;
          if (parts != null && parts.isNotEmpty) {
            return parts[0]['text'] as String;
          }
        }
        throw Exception('翻訳結果が取得できませんでした。');
      } else {
        throw Exception('APIエラー: ${response.statusCode} ${response.statusMessage}');
      }
    } on DioException catch (e) {
      if (e.response != null && e.response?.data != null) {
        final err = e.response?.data;
        throw Exception('Gemini API エラー: ${err['error']?['message'] ?? e.message}');
      }
      throw Exception('通信エラー: ${e.message}');
    }
  }

  /// 改行を意識して適切なサイズに分割する
  static List<String> _splitIntoChunks(String text, {int maxChunkSize = 2500}) {
    if (text.length <= maxChunkSize) {
      return [text];
    }

    final paragraphs = text.split('\n');
    final chunks = <String>[];
    StringBuffer currentChunk = StringBuffer();

    for (final p in paragraphs) {
      if (currentChunk.length + p.length > maxChunkSize && currentChunk.isNotEmpty) {
        chunks.add(currentChunk.toString());
        currentChunk = StringBuffer();
      }
      if (currentChunk.isNotEmpty) {
        currentChunk.write('\n');
      }
      currentChunk.write(p);
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk.toString());
    }

    return chunks;
  }
}
