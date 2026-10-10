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
  static Future<String> translateNovel(
    String rawText, {
    void Function(double progress, String status)? onProgress,
  }) async {
    final apiKey = await getApiKey();
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw Exception('Gemini APIキーが設定されていません。');
    }

    // チャンクサイズを約6000文字に設定
    final chunks = _splitIntoChunks(rawText, maxChunkSize: 6000);
    final translatedChunks = <String>[];

    for (int i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      if (onProgress != null) {
        final progress = (i + 1) / chunks.length;
        onProgress(progress, '翻訳中 (${i + 1}/${chunks.length})...');
      }

      if (i > 0) {
        await Future.delayed(const Duration(seconds: 2));
      }

      final translated = await _translateChunk(chunk, apiKey.trim());
      translatedChunks.add(translated);
    }

    return translatedChunks.join('\n\n');
  }

  /// 1チャンクをGemini APIに送信して翻訳
  /// 最新の Interactions API と従来の generateContent API の両方に対応
  static Future<String> _translateChunk(String chunk, String apiKey) async {
    final prompt =
        "$_systemInstruction\n\n【以下の中国語小説テキストを日本語に翻訳してください】\n$chunk";

    final models = [
      'gemini-3.8-flash',
      'gemini-2.5-flash',
      'gemini-1.5-flash',
      'gemini-3.5-flash',
    ];

    dynamic lastException;

    for (final model in models) {
      // 1. 最新の Interactions API (2026年推奨規格) を試行
      try {
        const interactionUrl =
            'https://generativelanguage.googleapis.com/v1beta/interactions';
        final response = await _dio.post(
          interactionUrl,
          data: {
            "model": model,
            "input": prompt,
          },
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey,
            },
            sendTimeout: const Duration(seconds: 45),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );

        if (response.statusCode == 200 && response.data != null) {
          final text = _extractTextFromResponse(response.data);
          if (text != null && text.trim().isNotEmpty) {
            return text.trim();
          }
        }
      } catch (e) {
        lastException = e;
      }

      // 2. 従来の generateContent API で試行
      try {
        final generateUrl =
            'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';
        final requestBody = {
          "contents": [
            {
              "role": "user",
              "parts": [
                {"text": prompt}
              ]
            }
          ],
          "generationConfig": {
            "temperature": 0.4,
            "maxOutputTokens": 8192,
          },
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

        final response = await _dio.post(
          generateUrl,
          data: requestBody,
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey,
            },
            sendTimeout: const Duration(seconds: 45),
            receiveTimeout: const Duration(seconds: 60),
          ),
        );

        if (response.statusCode == 200 && response.data != null) {
          final text = _extractTextFromResponse(response.data);
          if (text != null && text.trim().isNotEmpty) {
            return text.trim();
          }
        }
      } on DioException catch (e) {
        if (e.response != null && e.response?.data != null) {
          final err = e.response?.data;
          final msg = err['error']?['message'] ?? e.message;
          lastException = Exception('Gemini API ($model): $msg');
          continue;
        }
        lastException = e;
      } catch (e) {
        lastException = e;
      }
    }

    throw lastException ?? Exception('Gemini API で翻訳結果が取得できませんでした。');
  }

  /// レスポンスJSONから柔軟にテキストを抽出
  static String? _extractTextFromResponse(dynamic data) {
    if (data == null) return null;

    // 1. Interactions API 形式: data['steps']
    if (data['steps'] is List) {
      for (final step in data['steps']) {
        if (step['content'] is List) {
          for (final c in step['content']) {
            if (c['text'] is String && (c['text'] as String).isNotEmpty) {
              return c['text'] as String;
            }
          }
        }
        if (step['text'] is String && (step['text'] as String).isNotEmpty) {
          return step['text'] as String;
        }
      }
    }

    // 2. generateContent 形式: data['candidates']
    if (data['candidates'] is List && (data['candidates'] as List).isNotEmpty) {
      final cand = data['candidates'][0];
      if (cand['content'] != null && cand['content']['parts'] is List) {
        final parts = cand['content']['parts'] as List;
        if (parts.isNotEmpty && parts[0]['text'] is String) {
          return parts[0]['text'] as String;
        }
      }
    }

    // 3. 直接プロパティ
    if (data['output'] is String) return data['output'] as String;
    if (data['text'] is String) return data['text'] as String;

    return null;
  }

  /// 改行を意識して適切なサイズに分割する
  static List<String> _splitIntoChunks(String text, {int maxChunkSize = 6000}) {
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
