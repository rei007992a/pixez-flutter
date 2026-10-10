/*
 * Copyright (C) 2020. by perol_notsf, All rights reserved
 *
 * This program is free software: you can redistribute it and/or modify it under
 * the terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * this program. If not, see <http://www.gnu.org/licenses/>.
 *
 */

import 'dart:convert';
import 'dart:io';

import 'package:bot_toast/bot_toast.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_mobx/flutter_mobx.dart';
import 'package:mobx/mobx.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pixez/component/painter_avatar.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/component/selectable_html.dart';
import 'package:pixez/er/leader.dart';
import 'package:pixez/er/lprinter.dart';
import 'package:pixez/exts.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/ban_tag.dart';
import 'package:pixez/models/novel_recom_response.dart';
import 'package:pixez/models/novel_web_response.dart';
import 'package:pixez/page/comment/comment_page.dart';
import 'package:pixez/page/novel/component/novel_bookmark_button.dart';
import 'package:pixez/page/novel/search/novel_result_page.dart';
import 'package:pixez/page/novel/series/novel_series_page.dart';
import 'package:pixez/page/novel/user/novel_users_page.dart';
import 'package:pixez/page/novel/viewer/image_text.dart';
import 'package:pixez/page/novel/viewer/novel_store.dart';
import 'package:pixez/saf_plugin.dart';
import 'package:pixez/supportor_plugin.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path/path.dart' as Path;
import 'package:pixez/network/gemini_translator.dart';

class NovelViewerPage extends StatefulWidget {
  final int id;
  final NovelStore? novelStore;

  const NovelViewerPage({Key? key, required this.id, this.novelStore})
    : super(key: key);

  @override
  _NovelViewerPageState createState() => _NovelViewerPageState();
}

class _NovelViewerPageState extends State<NovelViewerPage> {
  ScrollController? _controller;
  late NovelStore _novelStore;
  ReactionDisposer? _offsetDisposer;
  double _localOffset = 0.0;
  bool supportTranslate = false;
  String _selectedText = "";
  NovelSpansGenerator novelSpansGenerator = NovelSpansGenerator();

  List<NovelSpansData>? _originalSpans;
  List<NovelSpansData>? _translatedSpans;
  String? _translatedTitle;
  String? _translatedCaption;
  bool _isShowingTranslated = false;
  bool _isTranslating = false;
  String? _translationProgressText;
  bool _syncedInitialTranslationState = false;
  void Function()? _dismissLoadingToast;

  void _dismissLoadingIfNeeded() {
    if (_dismissLoadingToast != null) {
      _dismissLoadingToast!();
      _dismissLoadingToast = null;
    }
  }

  /// 原作・キャラクター口調・固有名詞を正確に再現するためのメタ情報を構築
  String _buildNovelContext() {
    final novel = _novelStore.novel;
    if (novel == null) return '';
    final buffer = StringBuffer();
    buffer.writeln('作品タイトル: ${novel.title}');
    if (novel.series.title != null && novel.series.title!.trim().isNotEmpty) {
      buffer.writeln('シリーズ名: ${novel.series.title}');
    }
    buffer.writeln('作者名: ${novel.user.name}');
    if (novel.tags.isNotEmpty) {
      final tagDescriptions = novel.tags.map((t) {
        final jp = t.translatedName;
        if (jp != null && jp.trim().isNotEmpty && jp.trim() != t.name.trim()) {
          return '${t.name} (日本語公式表記: $jp)';
        }
        return t.name;
      }).join(' / ');
      buffer.writeln('登録タグ（原作名・登場キャラ・カップリング・属性）: $tagDescriptions');
    }
    return buffer.toString().trim();
  }

  List<NovelSpansData> _buildSpansFromText(String text) {
    final clonedMap =
        jsonDecode(jsonEncode(_novelStore.novelTextResponse!.toJson()));
    final translatedResponse = NovelWebResponse.fromJson(clonedMap);
    translatedResponse.text = text;
    return novelSpansGenerator.buildSpans(translatedResponse);
  }

  void _syncExistingTranslationStateIfNeeded() {
    if (_syncedInitialTranslationState) return;
    if (_novelStore.novelTextResponse == null || _novelStore.novel == null) {
      return;
    }
    _syncedInitialTranslationState = true;

    final cachedBody = GeminiTranslator.getCachedBody(widget.id);
    final isRunning = GeminiTranslator.isTranslatingNovel(widget.id);
    if (cachedBody == null && !isRunning) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _originalSpans ??= List.from(_novelStore.spans);
      final cTitle = GeminiTranslator.getCachedTitle(widget.id);
      final cCaption = GeminiTranslator.getCachedCaption(widget.id);

      if (cachedBody != null) {
        final spans = _buildSpansFromText(cachedBody);
        setState(() {
          _translatedTitle = cTitle;
          _translatedCaption = cCaption;
          _translatedSpans = spans;
          _isShowingTranslated = true;
          _isTranslating = false;
          _translationProgressText = null;
          _novelStore.spans = spans;
        });
      } else if (isRunning) {
        final partial = GeminiTranslator.getPartialBody(widget.id);
        final status = GeminiTranslator.getJobStatus(widget.id) ?? 'AI翻訳中...';
        GeminiTranslator.attachUiListener(
          widget.id,
          _onBackgroundTranslationUpdate,
        );
        setState(() {
          _translatedTitle = cTitle;
          _translatedCaption = cCaption;
          _isTranslating = true;
          _translationProgressText = status;
          if (partial != null && partial.isNotEmpty) {
            final spans = _buildSpansFromText(partial);
            _translatedSpans = spans;
            _isShowingTranslated = true;
            _novelStore.spans = spans;
          }
        });
      }
    });
  }

  void _onBackgroundTranslationUpdate(
    int completed,
    int total,
    String currentFullText,
    String statusMessage,
    bool isFinished,
    Object? error,
  ) {
    if (!mounted) return;

    final cTitle = GeminiTranslator.getCachedTitle(widget.id);
    final cCaption = GeminiTranslator.getCachedCaption(widget.id);
    if (cTitle != null) _translatedTitle = cTitle;
    if (cCaption != null) _translatedCaption = cCaption;

    if (error != null) {
      _dismissLoadingIfNeeded();
      final errMsg = error.toString().replaceFirst('Exception: ', '');
      setState(() {
        _isTranslating = false;
        _translationProgressText = null;
      });
      BotToast.showText(text: "翻訳失敗: $errMsg");
      GeminiTranslator.getApiKey().then((apiKey) {
        if (mounted) {
          _showTranslationErrorDialog(errMsg, apiKey);
        }
      });
      return;
    }

    if (completed > 0 || isFinished) {
      _dismissLoadingIfNeeded();
      final newSpans = _buildSpansFromText(currentFullText);
      setState(() {
        _translatedSpans = newSpans;
        _isShowingTranslated = true;
        _isTranslating = !isFinished;
        _translationProgressText = isFinished ? null : statusMessage;
        _novelStore.spans = _translatedSpans!;
      });

      if (completed == 1 && total > 1 && !isFinished) {
        BotToast.showText(
          text: "冒頭の翻訳が完了しました！他アプリ操作中もバックグラウンドで継続し完了時に通知します",
        );
      } else if (isFinished) {
        BotToast.showText(text: "全文の日本語翻訳が完了しました！");
      }
    } else {
      setState(() {
        _isTranslating = true;
        _translationProgressText = statusMessage;
      });
    }
  }

  Future<void> _translateNovel({bool forceRetranslate = false}) async {
    if (_isTranslating) {
      _showTranslationOptionsSheet();
      return;
    }

    if (!forceRetranslate && _translatedSpans != null) {
      setState(() {
        _isShowingTranslated = !_isShowingTranslated;
        _novelStore.spans =
            _isShowingTranslated ? _translatedSpans! : _originalSpans!;
      });
      BotToast.showText(
        text: _isShowingTranslated ? "日本語翻訳を表示中" : "中国語原文を表示中",
      );
      return;
    }

    String? apiKey = await GeminiTranslator.getApiKey();
    if (apiKey == null || apiKey.isEmpty) {
      final inputKey = await _showApiKeyDialog();
      if (inputKey == null || inputKey.isEmpty) return;
      apiKey = inputKey;
    }

    if (forceRetranslate) {
      GeminiTranslator.cancelNovelJob(widget.id);
      await GeminiTranslator.clearCache();
      _translatedSpans = null;
      _translatedTitle = null;
      _translatedCaption = null;
    }

    _originalSpans ??= List.from(_novelStore.spans);

    setState(() {
      _isTranslating = true;
      _translationProgressText = "AI翻訳を開始中...";
    });

    _dismissLoadingIfNeeded();
    _dismissLoadingToast = BotToast.showLoading();

    try {
      final rawTitle = _novelStore.novel?.title ?? "";
      final rawCaption = _novelStore.novel?.caption ?? "";
      final fullText = _novelStore.novelTextResponse!.text;
      final novelContext = _buildNovelContext();

      await GeminiTranslator.startBackgroundNovelTranslation(
        novelId: widget.id,
        rawText: fullText,
        rawTitle: rawTitle,
        rawCaption: rawCaption,
        novelContext: novelContext,
        onHeaderTranslated: (tTitle, tCaption) {
          if (!mounted) return;
          _dismissLoadingIfNeeded();
          setState(() {
            if (tTitle != null && tTitle.isNotEmpty) {
              _translatedTitle = tTitle;
            }
            if (tCaption != null && tCaption.isNotEmpty) {
              _translatedCaption = tCaption;
            }
            _isShowingTranslated = true;
          });
        },
        onUiUpdate: _onBackgroundTranslationUpdate,
      );
    } catch (e) {
      _dismissLoadingIfNeeded();
      final errMsg = e.toString().replaceFirst('Exception: ', '');
      if (mounted) {
        setState(() {
          _isTranslating = false;
          _translationProgressText = null;
        });
        BotToast.showText(text: "翻訳失敗: $errMsg");
        _showTranslationErrorDialog(errMsg, apiKey);
      }
    }
  }

  Future<void> _showTranslationErrorDialog(
    String errorMessage,
    String? currentKey,
  ) async {
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("AI翻訳エラー"),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  errorMessage,
                  style: TextStyle(fontSize: 13),
                ),
                SizedBox(height: 12),
                Text(
                  "※APIキーの制限や入力ミスの場合は「APIキーを変更」から再設定できます。",
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).textTheme.bodySmall?.color,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("閉じる"),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(context);
                final newKey = await _showApiKeyDialog(initialKey: currentKey);
                if (newKey != null && newKey.isNotEmpty) {
                  _translateNovel(forceRetranslate: true);
                }
              },
              child: Text("APIキーを変更"),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _translateNovel();
              },
              child: Text("再試行"),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showTranslationOptionsSheet() async {
    final currentKey = await GeminiTranslator.getApiKey();
    final maskedKey = (currentKey != null && currentKey.length > 10)
        ? "${currentKey.substring(0, 6)}...${currentKey.substring(currentKey.length - 4)}"
        : (currentKey ?? "未設定");

    if (!mounted) return;
    await showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.translate),
                title: Text("AI小説翻訳メニュー（バックグラウンド対応）"),
                subtitle: Text(
                  _isTranslating
                      ? "${_translationProgressText ?? "翻訳中..."}（他アプリ操作中も継続・完了時通知）"
                      : "現在のAPIキー: $maskedKey",
                ),
              ),
              Divider(height: 1),
              if (_translatedSpans != null)
                ListTile(
                  leading: Icon(Icons.swap_horiz),
                  title: Text(
                    _isShowingTranslated ? "中国語原文に切り替え" : "日本語翻訳に切り替え",
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    setState(() {
                      _isShowingTranslated = !_isShowingTranslated;
                      _novelStore.spans = _isShowingTranslated
                          ? _translatedSpans!
                          : _originalSpans!;
                    });
                  },
                ),
              if (_isTranslating)
                ListTile(
                  leading: Icon(Icons.stop_circle_outlined, color: Colors.red),
                  title: Text("バックグラウンド翻訳を中断する"),
                  onTap: () {
                    Navigator.pop(context);
                    _dismissLoadingIfNeeded();
                    GeminiTranslator.cancelNovelJob(widget.id);
                    setState(() {
                      _isTranslating = false;
                      _translationProgressText = null;
                    });
                    BotToast.showText(text: "翻訳を中断しました");
                  },
                ),
              ListTile(
                leading: Icon(Icons.key),
                title: Text("Gemini APIキーを変更・確認"),
                onTap: () async {
                  Navigator.pop(context);
                  final newKey =
                      await _showApiKeyDialog(initialKey: currentKey);
                  if (newKey != null && newKey.isNotEmpty && !_isTranslating) {
                    _translateNovel(forceRetranslate: true);
                  }
                },
              ),
              if (!_isTranslating)
                ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text("キャッシュを消去して最初から再翻訳"),
                  onTap: () {
                    Navigator.pop(context);
                    _translateNovel(forceRetranslate: true);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<String?> _showApiKeyDialog({String? initialKey}) async {
    final controller = TextEditingController(text: initialKey ?? "");
    return showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Gemini APIキーの設定"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Google AI Studio (aistudio.google.com/app/apikey) で取得したGemini APIキーを入力してください。",
                style: TextStyle(fontSize: 13),
              ),
              SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  hintText: "AIzaSy... または AQ....",
                  border: OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: IconButton(
                    icon: Icon(Icons.content_paste, size: 20),
                    tooltip: "貼り付け",
                    onPressed: () async {
                      final data =
                          await Clipboard.getData(Clipboard.kTextPlain);
                      if (data?.text != null) {
                        controller.text = data!.text!.trim();
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("キャンセル"),
            ),
            ElevatedButton(
              onPressed: () async {
                final key = controller.text.trim();
                if (key.isNotEmpty) {
                  await GeminiTranslator.saveApiKey(key);
                  Navigator.pop(context, key);
                }
              },
              child: Text("保存して翻訳"),
            ),
          ],
        );
      },
    );
  }

  Future<void> initMethod() async {
    if (!Platform.isAndroid) return;
    bool results = await SupportorPlugin.processText();
    if (mounted) {
      setState(() {
        supportTranslate = results;
      });
    }
  }

  @override
  void initState() {
    _novelStore = widget.novelStore ?? NovelStore(widget.id, null);
    _offsetDisposer = reaction((_) => _novelStore.bookedOffset, (_) {
      LPrinter.d("jump to ${_novelStore.bookedOffset}");
      _controller?.jumpTo(_novelStore.bookedOffset);
    });
    _novelStore.fetch();
    super.initState();
    initMethod();
  }

  @override
  void dispose() {
    _dismissLoadingIfNeeded();
    // 画面を離れてもバックグラウンド翻訳自体は継続させ、UIリスナーのみ解除
    GeminiTranslator.attachUiListener(widget.id, null);
    _offsetDisposer?.call();
    if (_novelStore.positionBooked) {
      _novelStore.bookPosition(_localOffset);
    }
    _controller?.dispose();
    super.dispose();
  }

  final double leading = 0.9;
  final double textLineHeight = 2;
  final double fontSize = 16;
  TextStyle? _textStyle;

  @override
  Widget build(BuildContext context) {
    return Observer(
      builder: (context) {
        _textStyle = Theme.of(
          context,
        ).textTheme.bodyLarge!.copyWith(
          fontSize: userSetting.novelFontsize,
          height: 1.75,
        );
        if (_novelStore.errorMessage != null) {
          return _buildErrorContent(context);
        }
        if (_novelStore.novelTextResponse != null &&
            _novelStore.novel != null) {
          _syncExistingTranslationStateIfNeeded();
          _textStyle =
              _textStyle ?? Theme.of(context).textTheme.bodyLarge!.copyWith(height: 1.75);
          if (_controller == null) {
            LPrinter.d("init Controller ${_novelStore.bookedOffset}");
            _controller = ScrollController(
              initialScrollOffset: _novelStore.bookedOffset,
            );
            _controller?.addListener(() {
              if (_controller!.hasClients) _localOffset = _controller!.offset;
            });
          }
          return Scaffold(
            appBar: _buildAppbar(context),
            extendBodyBehindAppBar: true,
            body: _buildBody(context),
          );
        }
        return Scaffold(
          appBar: AppBar(elevation: 0.0, backgroundColor: Colors.transparent),
          body: Container(child: Center(child: CircularProgressIndicator())),
        );
      },
    );
  }

  Scaffold _buildErrorContent(BuildContext context) {
    return Scaffold(
      appBar: AppBar(elevation: 0.0),
      extendBody: true,
      extendBodyBehindAppBar: true,
      body: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.max,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Container(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Center(
                  child: Text(
                    ':(',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                _novelStore.fetch();
              },
              child: Text(I18n.of(context).retry),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text('${_novelStore.errorMessage}'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return ListView.builder(
      padding: EdgeInsets.all(0),
      controller: _controller,
      itemBuilder: (context, index) {
        if (index == 0) {
          return _buildHeader(context);
        } else if (index == _novelStore.spans.length + 1) {
          return _buildCommentButton(context);
        } else if (index == _novelStore.spans.length + 2) {
          return Container(height: 10 + MediaQuery.of(context).padding.bottom);
        } else {
          return _buildSpanText(context, index - 1, _novelStore.spans);
        }
      },
      itemCount: 3 + _novelStore.spans.length,
    );
  }

  AppBar _buildAppbar(BuildContext context) {
    return AppBar(
      elevation: 0.0,
      leading: IconButton(
        icon: Icon(
          Icons.arrow_back,
          color: Theme.of(context).textTheme.bodyLarge!.color,
        ),
        onPressed: () {
          Navigator.of(context).pop();
        },
      ),
      title: Text(
        (_isTranslating && _translationProgressText != null)
            ? _translationProgressText!
            : _novelStore.novelTextResponse!.text.length.toString(),
        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
          fontSize: (_isTranslating && _translationProgressText != null)
              ? 13
              : null,
        ),
      ),
      backgroundColor: Colors.transparent,
      actions: <Widget>[
        GestureDetector(
          onLongPress: _showTranslationOptionsSheet,
          child: IconButton(
            icon: _isTranslating
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  )
                : Icon(
                    _isShowingTranslated ? Icons.translate : Icons.g_translate,
                    color: _isShowingTranslated
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).textTheme.bodyLarge!.color,
                  ),
            tooltip: _isShowingTranslated
                ? "原文に戻す（長押しでメニュー）"
                : "AI官能翻訳（長押しでメニュー）",
            onPressed: () => _translateNovel(),
          ),
        ),
        NovelBookmarkButton(novel: _novelStore.novel!),
        IconButton(
          onPressed: () {
            if (_novelStore.positionBooked)
              _novelStore.deleteBookPosition();
            else
              _novelStore.bookPosition(_controller!.offset);
          },
          icon: Icon(Icons.history),
          color: Theme.of(context).textTheme.bodyLarge!.color!.withAlpha(
            _novelStore.positionBooked ? 225 : 120,
          ),
        ),
        Builder(
          builder: (context) {
            return IconButton(
              icon: Icon(
                Icons.more_vert,
                color: Theme.of(context).textTheme.bodyLarge!.color,
              ),
              onPressed: () {
                _showMessage(context);
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildSpanText(
    BuildContext context,
    int index,
    List<NovelSpansData> spanDatas,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: SelectionArea(
        onSelectionChanged: (value) {
          _selectedText = value?.plainText ?? "";
        },
        contextMenuBuilder: (context, editableTextState) {
          return _buildSelectionMenu(editableTextState, context);
        },
        child: Text.rich(
          novelSpansGenerator.novelSpansDatatoInlineSpan(
            context,
            spanDatas[index],
          ),
          style: _textStyle,
          textHeightBehavior: TextHeightBehavior(
            applyHeightToLastDescent: true,
          ),
        ),
      ),
    );
  }

  Widget _buildCommentButton(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 16.0, horizontal: 16.0),
      child: Center(
        child: TextButton(
          onPressed: () {
            Leader.push(
              context,
              CommentPage(id: _novelStore.id, type: CommentArtWorkType.NOVEL),
            );
          },
          child: Text(
            '${I18n.of(context).view_comment}(${_novelStore.novel?.totalComments ?? 0})',
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      child: Column(
        children: [
          Container(height: 100),
          Center(
            child: Container(
              height: 160,
              child: PixivImage(_novelStore.novel!.imageUrls.medium),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(
              left: 16.0,
              right: 16.0,
              top: 12.0,
              bottom: 8.0,
            ),
            child: Text(
              (_isShowingTranslated &&
                      _translatedTitle != null &&
                      _translatedTitle!.isNotEmpty)
                  ? _translatedTitle!
                  : "${_novelStore.novel!.title}",
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (_novelStore.novel?.series.id != null)
            Padding(
              padding: const EdgeInsets.only(
                left: 16.0,
                right: 16.0,
                top: 0.0,
                bottom: 0.0,
              ),
              child: InkWell(
                onTap: () {
                  Leader.push(
                    context,
                    NovelSeriesPage(_novelStore.novel!.series.id!),
                  );
                },
                child: Text(
                  "Series:${_novelStore.novel!.series.title}",
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ),
          //MARK DETAIL NUM,
          _buildNumItem(_novelStore.novel!),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: Text(
              "${_novelStore.novel!.createDate}",
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(
              vertical: 8.0,
              horizontal: 16.0,
            ),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 2,
              runSpacing: 0,
              children: [
                if (_novelStore.novel!.NovelAIType == 2)
                  Text(
                    "${I18n.of(context).ai_generated}",
                    style: Theme.of(context).textTheme.bodySmall!.copyWith(
                      color: Theme.of(context).colorScheme.secondary,
                    ),
                  ),
                for (var f in _novelStore.novel!.tags) buildRow(context, f),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: SelectionArea(
                  onSelectionChanged: (value) {
                    _selectedText = value?.plainText ?? "";
                  },
                  contextMenuBuilder: (context, editableTextState) {
                    return _buildSelectionMenu(editableTextState, context);
                  },
                  child: SelectableHtml(
                    data: (_isShowingTranslated &&
                            _translatedCaption != null &&
                            _translatedCaption!.isNotEmpty)
                        ? _translatedCaption!
                        : (_novelStore.novel?.caption ?? ""),
                  ),
                ),
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8.0),
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Leader.push(
                context,
                CommentPage(id: _novelStore.id, type: CommentArtWorkType.NOVEL),
              );
            },
            child: Text(
              '${I18n.of(context).view_comment}(${_novelStore.novel?.totalComments ?? 0})',
            ),
          ),
        ],
      ),
    );
  }

  AdaptiveTextSelectionToolbar _buildSelectionMenu(
    SelectableRegionState editableTextState,
    BuildContext context,
  ) {
    final List<ContextMenuButtonItem> buttonItems =
        editableTextState.contextMenuButtonItems;
    if (supportTranslate) {
      buttonItems.insert(
        buttonItems.length,
        ContextMenuButtonItem(
          label: I18n.of(context).translate,
          onPressed: () async {
            final selectionText = _selectedText;
            if (Platform.isIOS) {
              final box = context.findRenderObject() as RenderBox?;
              final pos = box != null
                  ? box.localToGlobal(Offset.zero) & box.size
                  : null;
              SharePlus.instance.share(
                ShareParams(text: selectionText, sharePositionOrigin: pos),
              );
              return;
            }
            await SupportorPlugin.start(selectionText);
            ContextMenuController.removeAny();
          },
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  Future<void> _showSettings(BuildContext context) async {
    await showModalBottomSheet(
      context: context,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setB) {
            return SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.max,
                    children: [
                      Container(
                        child: Icon(Icons.text_fields),
                        margin: EdgeInsets.only(left: 16),
                      ),
                      Container(
                        child: Text(_textStyle!.fontSize!.toInt().toString()),
                        margin: EdgeInsets.only(left: 16),
                      ),
                      Expanded(
                        child: Slider(
                          value: _textStyle!.fontSize! / 32,
                          onChanged: (v) {
                            setB(() {
                              _textStyle = _textStyle!.copyWith(
                                fontSize: v * 32,
                              );
                            });
                            userSetting.setNovelFontsizeWithoutSave(v * 32);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
    userSetting.setNovelFontsize(_textStyle!.fontSize!);
  }

  Future _longPressTag(BuildContext context, Tag f) async {
    switch (await showDialog(
      context: context,
      builder: (BuildContext context) {
        return SimpleDialog(
          title: Text(f.name),
          children: <Widget>[
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context, 0);
              },
              child: Text(I18n.of(context).ban),
            ),
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(context, 2);
              },
              child: Text(I18n.of(context).copy),
            ),
          ],
        );
      },
    )) {
      case 0:
        {
          await muteStore.insertBanTag(
            BanTagPersist(name: f.name, translateName: f.translatedName ?? ""),
          );
          Navigator.of(context).pop();
        }
        break;
      case 2:
        {
          await Clipboard.setData(ClipboardData(text: f.name));
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              duration: Duration(seconds: 1),
              content: Text(I18n.of(context).copied_to_clipboard),
            ),
          );
        }
    }
  }

  Widget buildRow(BuildContext context, Tag f) {
    return GestureDetector(
      onLongPress: () async {
        _longPressTag(context, f);
      },
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (context) {
              return NovelResultPage(
                word: f.name,
                translatedName: f.translatedName ?? "",
              );
            },
          ),
        );
      },
      child: RichText(
        textAlign: TextAlign.center,
        text: TextSpan(
          text: "#${f.name}",
          children: [
            TextSpan(text: " ", style: Theme.of(context).textTheme.bodySmall),
            TextSpan(
              text: "${f.translatedName ?? "~"}",
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          style: Theme.of(context).textTheme.bodySmall!.copyWith(
            color: Theme.of(context).colorScheme.secondary,
          ),
        ),
      ),
    );
  }

  Widget _buildNumItem(Novel novel) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 2,
        runSpacing: 0,
        children: [
          Text(I18n.of(context).total_bookmark),
          Text(
            "${novel.totalBookmarks}",
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8.0),
            child: Text(I18n.of(context).total_view),
          ),
          Text(
            "${novel.totalView}",
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ],
      ),
    );
  }

  Future _showMessage(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16.0)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ListTile(
                subtitle: Text(_novelStore.novel!.user.name, maxLines: 2),
                title: Text(_novelStore.novel!.title, maxLines: 2),
                leading: Container(
                  child: PainterAvatar(
                    url: _novelStore.novel!.user.profileImageUrls.medium,
                    id: _novelStore.novel!.user.id,
                    size: Size(40, 40),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (context) {
                            return NovelUsersPage(
                              id: _novelStore.novel!.user.id,
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(I18n.of(context).pre),
              ),
              buildListTile(
                _novelStore.novelTextResponse!.seriesNavigation?.prevNovel,
              ),
              Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0),
                child: Text(I18n.of(context).next),
              ),
              buildListTile(
                _novelStore.novelTextResponse!.seriesNavigation?.nextNovel,
              ),
              if (Platform.isAndroid)
                ListTile(
                  title: Text(I18n.of(context).export),
                  leading: Icon(Icons.folder_zip),
                  onTap: () {
                    _export();
                  },
                ),
              ListTile(
                title: Text("AI翻訳設定 / APIキー変更"),
                leading: Icon(Icons.g_translate),
                onTap: () {
                  Navigator.of(context).pop();
                  _showTranslationOptionsSheet();
                },
              ),
              ListTile(
                title: Text(I18n.of(context).setting),
                leading: Icon(Icons.settings),
                onTap: () {
                  Navigator.of(context).pop();
                  _showSettings(context);
                },
              ),
              Builder(
                builder: (context) {
                  return ListTile(
                    title: Text(I18n.of(context).share),
                    leading: Icon(Icons.share),
                    onTap: () {
                      Navigator.of(context).pop();
                      final box = context.findRenderObject() as RenderBox?;
                      final pos = box != null
                          ? box.localToGlobal(Offset.zero) & box.size
                          : null;
                      final link =
                          "https://www.pixiv.net/novel/show.php?id=${widget.id}";
                      SharePlus.instance.share(
                        ShareParams(text: link, sharePositionOrigin: pos),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Widget buildListTile(PrevNovel? series) {
    if (series == null) return ListTile(title: Text("no more"));
    return ListTile(
      title: Text(
        series.title ?? series.contentOrder,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      enabled: series.viewable,
      onTap: series.viewable
          ? () {
              Navigator.of(context, rootNavigator: true).pushReplacement(
                MaterialPageRoute(
                  builder: (BuildContext context) => NovelViewerPage(
                    id: series.id,
                    novelStore: NovelStore(series.id, null),
                  ),
                ),
              );
            }
          : null,
    );
  }

  void _export() async {
    if (_novelStore.novelTextResponse == null) return;
    if (Platform.isAndroid) {
      // final path = await getExternalStorageDirectory();
      // if (path == null) return;
      // final dirPath = Path.join(path.path, "novel_export");
      // final dir = Directory(dirPath);
      // if (!dir.existsSync()) {
      //   dir.createSync(recursive: true);
      // }
      // final allPath = Path.join(dirPath, "All");
      // final allDir = Directory(allPath);
      // if (!allDir.existsSync()) {
      //   allDir.createSync(recursive: true);
      // }
      // final novelDirPath =
      //     Path.join(dirPath, _novelStore.novel!.title.trim().toLegal());
      // final novelDir = Directory(novelDirPath);
      // if (!novelDir.existsSync()) {
      //   novelDir.createSync(recursive: true);
      // }
      // final fileInAllPath = Path.join(
      //     allPath, "${_novelStore.novel!.title.trim().toLegal()}.txt");
      // final filePath = Path.join(novelDirPath, "${_novelStore.novel!.id}.txt");
      // final resultFile = File(filePath);
      // final data = _novelStore.novelTextResponse!.text;
      // resultFile.writeAsStringSync(data);
      // File(fileInAllPath).writeAsStringSync(data);
      // BotToast.showText(text: "export ${filePath}");
      final data = _novelStore.novelTextResponse!.text;
      final uri = await SAFPlugin.createFile(
        "${_novelStore.novel!.title.trim().toLegal()}.txt",
        "application/txt",
      );
      await SAFPlugin.writeUri(uri!, utf8.encode(data));
      BotToast.showText(text: "export success");
    } else if (Platform.isIOS) {
      final path = await getApplicationDocumentsDirectory();
      final dirPath = Path.join(path.path, "novel_export");
      final dir = Directory(dirPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final allPath = Path.join(dirPath, "All");
      final allDir = Directory(allPath);
      if (!allDir.existsSync()) {
        allDir.createSync(recursive: true);
      }
      final novelDirPath = Path.join(
        dirPath,
        _novelStore.novel!.title.trim().toLegal(),
      );
      final novelDir = Directory(novelDirPath);
      if (!novelDir.existsSync()) {
        novelDir.createSync(recursive: true);
      }
      final fileInAllPath = Path.join(
        allPath,
        "${_novelStore.novel!.title.trim().toLegal()}.txt",
      );
      final filePath = Path.join(novelDirPath, "${_novelStore.novel!.id}.txt");
      final resultFile = File(filePath);
      final data = _novelStore.novelTextResponse!.text;
      resultFile.writeAsStringSync(data);
      File(fileInAllPath).writeAsStringSync(data);
      LPrinter.d("path: $filePath");
      BotToast.showText(text: "export ${filePath}");
    }
  }
}
