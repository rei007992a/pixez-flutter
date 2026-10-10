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

    // チャンクサイズを約6000文字に拡大（一般的な短編なら1回で完了）
    final chunks = _splitIntoChunks(rawText, maxChunkSize: 6000);
    final translatedChunks = <String>[];

    for (int i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      if (onProgress != null) {
        final progress = (i + 1) / chunks.length;
        onProgress(progress, '翻訳中 (${i + 1}/${chunks.length})...');
      }

      if (i > 0) {
        // レートリミット回避のための短いインターバル
        await Future.delayed(const Duration(seconds: 2));
      }

      final translated = await _translateChunk(chunk, apiKey.trim());
      translatedChunks.add(translated);
    }

    return translatedChunks.join('\n\n');
  }

  static String? _cachedWorkingModel;

  /// 利用可能なテキスト生成モデル一覧をGoogle APIから自動取得
  static Future<List<String>> _getAvailableModels(String apiKey) async {
    if (_cachedWorkingModel != null) {
      return [_cachedWorkingModel!];
    }

    try {
      final listUrl =
          'https://generativelanguage.googleapis.com/v1beta/models?key=$apiKey';
      final response = await _dio.get(
        listUrl,
        options: Options(
          headers: {'x-goog-api-key': apiKey},
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );

      if (response.statusCode == 200 && response.data != null) {
        final modelsList = response.data['models'] as List?;
        if (modelsList != null) {
          final matched = <String>[];
          for (final m in modelsList) {
            final name = m['name'] as String? ?? '';
            final methods = m['supportedGenerationMethods'] as List? ?? [];
            if (methods.contains('generateContent')) {
              final cleanName = name.replaceFirst('models/', '');
              final lower = cleanName.toLowerCase();
              // 音声書き起こし、TTS、画像生成、埋め込み等の特殊モデルを徹底除外
              if (lower.contains('transcribe') ||
                  lower.contains('tts') ||
                  lower.contains('imagen') ||
                  lower.contains('embedding') ||
                  lower.contains('aqa') ||
                  lower.contains('robotics')) {
                continue;
              }
              matched.add(cleanName);
            }
          }
          if (matched.isNotEmpty) {
            // 純粋なflashモデルを最優先、次にproモデル
            matched.sort((a, b) {
              final aFlash = a.contains('flash');
              final bFlash = b.contains('flash');
              if (aFlash && !bFlash) return -1;
              if (!aFlash && bFlash) return 1;
              return b.compareTo(a);
            });
            return matched;
          }
        }
      }
    } catch (_) {
      // 取得失敗時は静的フォールバック
    }

    return [
      'gemini-2.5-flash',
      'gemini-3.5-flash',
      'gemini-3.8-flash',
      'gemini-1.5-flash-latest',
      'gemini-1.5-flash',
      'gemini-2.0-flash-exp',
    ];
  }

  /// 1チャンクをGemini APIに送信して翻訳
  static Future<String> _translateChunk(String chunk, String apiKey) async {
    final models = await _getAvailableModels(apiKey);
    dynamic lastException;

    for (final model in models) {
      final url =
          'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';

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
            headers: {
              'Content-Type': 'application/json',
              'x-goog-api-key': apiKey,
            },
            sendTimeout: const Duration(seconds: 60),
            receiveTimeout: const Duration(seconds: 90),
          ),
        );

        if (response.statusCode == 200) {
          final data = response.data;
          final candidates = data['candidates'] as List?;
          if (candidates != null && candidates.isNotEmpty) {
            final content = candidates[0]['content'];
            final parts = content['parts'] as List?;
            if (parts != null && parts.isNotEmpty) {
              _cachedWorkingModel = model;
              return parts[0]['text'] as String;
            }
          }
        }
      } on DioException catch (e) {
        if (e.response != null && e.response?.data != null) {
          final err = e.response?.data;
          final msg = err['error']?['message'] ?? e.message;
          lastException = Exception('Gemini API エラー ($model): $msg');
          // モデル未対応またはクォータ超過（429）の場合、次のモデルへフォールバック
          continue;
        }
        lastException = e;
      } catch (e) {
        lastException = e;
      }
    }

    throw lastException ?? Exception('Gemini API で翻訳結果が取得できませんでした。');
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
