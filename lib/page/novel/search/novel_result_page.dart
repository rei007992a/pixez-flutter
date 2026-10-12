import 'dart:async';
import 'package:dio/dio.dart';
import 'package:easy_refresh/easy_refresh.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pixez/component/pixez_default_header.dart';
import 'package:pixez/component/pixiv_image.dart';
import 'package:pixez/exts.dart';
import 'package:pixez/i18n.dart';
import 'package:pixez/main.dart';
import 'package:pixez/models/novel_recom_response.dart';
import 'package:pixez/models/tags.dart';
import 'package:pixez/network/api_client.dart';
import 'package:pixez/page/novel/component/novel_bookmark_button.dart';
import 'package:pixez/page/novel/search/novel_result_list.dart';
import 'package:pixez/page/novel/viewer/novel_store.dart';
import 'package:pixez/page/novel/viewer/novel_viewer.dart';
import 'package:pixez/page/painter/painter_list.dart';
import 'package:pixez/utils/haptic_util.dart';

class NovelResultPage extends StatefulWidget {
  final String word;
  final String? translatedName;

  const NovelResultPage({Key? key, required this.word, this.translatedName})
    : super(key: key);

  @override
  _NovelResultPageState createState() => _NovelResultPageState();
}

class _NovelResultPageState extends State<NovelResultPage> {
  late String _currentWord;

  @override
  void initState() {
    super.initState();
    _currentWord = widget.word.trim();
    tagHistoryStore.insert(
      TagsPersist(
        name: _currentWord,
        translatedName: widget.translatedName ?? "",
      ),
    );
  }

  void _openUserSearchSheet(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text('$_currentWord - ${I18n.of(context).painter}'),
          ),
          body: PainterList(
            futureGet: () => apiClient.getSearchUser(_currentWord),
            isNovel: true,
          ),
        ),
      ),
    );
  }

  Future<void> _openSearchWordEditor() async {
    HapticUtil.selectionClick();
    final updatedWord = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (context) => _NovelSearchWordEditorPage(
          initialWord: _currentWord,
        ),
      ),
    );
    if (updatedWord != null &&
        updatedWord.trim().isNotEmpty &&
        updatedWord.trim() != _currentWord) {
      final clean = updatedWord.trim();
      tagHistoryStore.insert(
        TagsPersist(
          name: clean,
          translatedName: "",
        ),
      );
      setState(() {
        _currentWord = clean;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          titleSpacing: 4,
          title: InkWell(
            onTap: _openSearchWordEditor,
            borderRadius: BorderRadius.circular(22),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withAlpha(130),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.search,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _currentWord,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontSize: 15,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Icon(
                    Icons.add_circle_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ),
          ),
          actions: [
            IconButton(
              icon: Icon(Icons.person_search),
              tooltip: I18n.of(context).painter,
              onPressed: () => _openUserSearchSheet(context),
            ),
          ],
          bottom: TabBar(
            onTap: (i) {
              HapticUtil.selectionClick();
            },
            tabs: [
              Tab(child: Text('Novel')),
              Tab(child: Text('ランキング')),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            NovelResultList(
              key: ValueKey('novel_list_$_currentWord'),
              word: _currentWord,
            ),
            NovelKeywordRankingView(
              key: ValueKey('novel_rank_$_currentWord'),
              word: _currentWord,
            ),
          ],
        ),
      ),
    );
  }
}

/// 上部の検索バーをタップした際に検索ワードを追加・編集できるページ
class _NovelSearchWordEditorPage extends StatefulWidget {
  final String initialWord;

  const _NovelSearchWordEditorPage({Key? key, required this.initialWord})
    : super(key: key);

  @override
  State<_NovelSearchWordEditorPage> createState() =>
      _NovelSearchWordEditorPageState();
}

class _NovelSearchWordEditorPageState
    extends State<_NovelSearchWordEditorPage> {
  late TextEditingController _controller;
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;
  List<Tags> _autoCompleteTags = [];
  List<String> _relatedTags = [];
  bool _loadingRelated = true;

  @override
  void initState() {
    super.initState();
    final initClean = widget.initialWord.trim();
    // すぐに追加ワードを入力できるよう末尾に半角スペースを付与してカーソルを末尾に配置
    final initialText = initClean.isEmpty ? '' : '$initClean ';
    _controller = TextEditingController(text: initialText);
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    tagHistoryStore.fetch();
    _loadRelatedTagsFromNovels(initClean);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  List<String> get _currentWordTokens {
    return _controller.text
        .split(RegExp(r'[\s　]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<void> _loadRelatedTagsFromNovels(String baseWord) async {
    if (baseWord.isEmpty) {
      if (mounted) setState(() => _loadingRelated = false);
      return;
    }
    try {
      final freq = <String, int>{};
      final existing = baseWord
          .split(RegExp(r'[\s　]+'))
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toSet();

      final responses = await Future.wait<Response?>([
        apiClient.getPopularPreviewNovel(baseWord).catchError((_) => Response(requestOptions: RequestOptions(path: ''))),
        apiClient.getSearchNovel(baseWord).catchError((_) => Response(requestOptions: RequestOptions(path: ''))),
      ]);

      for (final res in responses) {
        if (res?.data != null && res!.data['novels'] is List) {
          final novels = NovelRecomResponse.fromJson(res.data).novels;
          for (final n in novels) {
            for (final t in n.tags) {
              final name = t.name.trim();
              if (name.isEmpty || existing.contains(name)) continue;
              freq[name] = (freq[name] ?? 0) + 1;
            }
          }
        }
      }

      final sorted = freq.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      if (mounted) {
        setState(() {
          _relatedTags = sorted.take(24).map((e) => e.key).toList();
          _loadingRelated = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingRelated = false);
      }
    }
  }

  void _onTextChanged(String value) {
    setState(() {});
    _debounce?.cancel();

    // 末尾が空白でない場合、現在入力中の最後の単語に対してPixiv公式オートコンプリートを実行
    if (value.isEmpty || value.endsWith(' ') || value.endsWith('　')) {
      setState(() {
        _autoCompleteTags = [];
      });
      return;
    }

    final tokens = value
        .split(RegExp(r'[\s　]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return;
    final lastWord = tokens.last;
    if (lastWord.isEmpty) return;

    _debounce = Timer(const Duration(milliseconds: 220), () async {
      try {
        final autoWords = await apiClient.getSearchAutoCompleteKeywords(lastWord);
        if (mounted) {
          setState(() {
            _autoCompleteTags = autoWords.tags;
          });
        }
      } catch (_) {}
    });
  }

  void _appendOrToggleTag(String tag) {
    HapticUtil.selectionClick();
    final tokens = _currentWordTokens;
    if (tokens.contains(tag)) {
      tokens.remove(tag);
    } else {
      tokens.add(tag);
    }
    final nextText = tokens.isEmpty ? '' : '${tokens.join(' ')} ';
    setState(() {
      _controller.text = nextText;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
      _autoCompleteTags = [];
    });
    _focusNode.requestFocus();
  }

  void _replaceLastTokenWithSuggestion(String suggestedTag, {bool submitNow = false}) {
    HapticUtil.selectionClick();
    final tokens = _currentWordTokens;
    if (tokens.isEmpty) {
      tokens.add(suggestedTag);
    } else {
      tokens[tokens.length - 1] = suggestedTag;
    }
    final nextText = '${tokens.join(' ')} ';
    if (submitNow) {
      Navigator.of(context).pop(tokens.join(' '));
      return;
    }
    setState(() {
      _controller.text = nextText;
      _controller.selection = TextSelection.fromPosition(
        TextPosition(offset: _controller.text.length),
      );
      _autoCompleteTags = [];
    });
    _focusNode.requestFocus();
  }

  void _submitSearch() {
    final query = _currentWordTokens.join(' ').trim();
    if (query.isEmpty) return;
    Navigator.of(context).pop(query);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = _currentWordTokens;
    final historyTags = tagHistoryStore.tags
        .map((e) => e.name.trim())
        .where((name) => name.isNotEmpty && !tokens.contains(name))
        .toSet()
        .take(15)
        .toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _controller,
          focusNode: _focusNode,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onTextChanged,
          onSubmitted: (_) => _submitSearch(),
          style: Theme.of(context).textTheme.titleMedium,
          decoration: const InputDecoration(
            hintText: 'スペース区切りで検索ワードを追加...',
            border: InputBorder.none,
          ),
        ),
        actions: [
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.backspace_outlined, size: 20),
              tooltip: 'クリア',
              onPressed: () {
                setState(() {
                  _controller.clear();
                  _autoCompleteTags = [];
                });
                _focusNode.requestFocus();
              },
            ),
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: FilledButton.icon(
              onPressed: tokens.isEmpty ? null : _submitSearch,
              icon: const Icon(Icons.search, size: 18),
              label: const Text('検索'),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        children: [
          // 1. 現在の検索タグ（タップや×で個別に削除可能）
          if (tokens.isNotEmpty) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '現在の検索ワード（×で個別削除）',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton.icon(
                  onPressed: () {
                    if (!_controller.text.endsWith(' ')) {
                      setState(() {
                        _controller.text = '${_controller.text} ';
                        _controller.selection = TextSelection.fromPosition(
                          TextPosition(offset: _controller.text.length),
                        );
                      });
                    }
                    _focusNode.requestFocus();
                  },
                  icon: const Icon(Icons.space_bar, size: 16),
                  label: const Text('スペース追加', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final t in tokens)
                  InputChip(
                    label: Text(t, style: const TextStyle(fontSize: 13)),
                    onDeleted: () => _appendOrToggleTag(t),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const Divider(height: 20),
          ],

          // 2. 入力中のPixiv公式タグ予測変換候補
          if (_autoCompleteTags.isNotEmpty) ...[
            Text(
              'タグ予測候補（タップで追加して検索 ／ 右の＋で入力欄に追加のみ）',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: Theme.of(context).colorScheme.secondary,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final tag in _autoCompleteTags.take(10))
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.tag, size: 18),
                      title: Text(tag.name),
                      subtitle: (tag.translated_name != null &&
                              tag.translated_name!.isNotEmpty)
                          ? Text(tag.translated_name!)
                          : null,
                      onTap: () => _replaceLastTokenWithSuggestion(
                        tag.name,
                        submitNow: true,
                      ),
                      trailing: IconButton(
                        icon: Icon(
                          Icons.add_circle_outline,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                        tooltip: '入力欄に追加してさらに絞り込む',
                        onPressed: () => _replaceLastTokenWithSuggestion(
                          tag.name,
                          submitNow: false,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],

          // 3. ワンタップで追加できる関連タグ・人気タグ
          Text(
            '＋ ワンタップで検索ワードを追加（関連タグ・人気条件）',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final preset in const ['R-18', 'R-18G', '1000users入り', '5000users入り'])
                if (!tokens.contains(preset))
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 15),
                    label: Text(preset, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _appendOrToggleTag(preset),
                  ),
              for (final rel in _relatedTags)
                if (!tokens.contains(rel))
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 15),
                    label: Text(rel, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _appendOrToggleTag(rel),
                  ),
            ],
          ),
          if (_loadingRelated)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),

          // 4. 検索履歴から追加
          if (historyTags.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              '＋ 検索履歴からワードを追加',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final h in historyTags)
                  ActionChip(
                    avatar: const Icon(Icons.history, size: 15),
                    label: Text(h, style: const TextStyle(fontSize: 12)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _appendOrToggleTag(h),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

enum _AgeFilter { all, r18Only, safeOnly }

/// 検索ワード内の「日刊ランキング」「総合ランキング」をプレミアム未加入でも利用できるビュー
class NovelKeywordRankingView extends StatefulWidget {
  final String word;

  const NovelKeywordRankingView({Key? key, required this.word})
    : super(key: key);

  @override
  State<NovelKeywordRankingView> createState() =>
      _NovelKeywordRankingViewState();
}

class _NovelKeywordRankingViewState extends State<NovelKeywordRankingView>
    with SingleTickerProviderStateMixin, AutomaticKeepAliveClientMixin {
  late TabController _subTabController;
  int _selectedSubTab = 0;
  _AgeFilter _ageFilter = _AgeFilter.all;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _subTabController = TabController(length: 2, vsync: this);
    _subTabController.addListener(() {
      if (_subTabController.index != _selectedSubTab && mounted) {
        setState(() {
          _selectedSubTab = _subTabController.index;
        });
      }
    });
  }

  @override
  void dispose() {
    _subTabController.dispose();
    super.dispose();
  }

  String _ageFilterLabel(_AgeFilter f) {
    switch (f) {
      case _AgeFilter.all:
        return 'すべて';
      case _AgeFilter.r18Only:
        return 'R-18のみ';
      case _AgeFilter.safeOnly:
        return '全年齢';
    }
  }

  Widget _buildSubTabPill(int index, String label) {
    final isSelected = _selectedSubTab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticUtil.selectionClick();
          setState(() {
            _selectedSubTab = index;
          });
          _subTabController.animateTo(index);
        },
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 36,
          alignment: Alignment.center,
          decoration: isSelected
              ? BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(18),
                )
              : null,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected
                  ? Theme.of(context).colorScheme.onSecondaryContainer
                  : Theme.of(context).textTheme.bodyMedium?.color,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: Theme.of(context).dividerColor.withAlpha(40),
                width: 1,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: Theme.of(context).dividerColor.withAlpha(25),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      _buildSubTabPill(0, '🔥 日刊ランキング'),
                      _buildSubTabPill(1, '👑 総合ランキング'),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<_AgeFilter>(
                initialValue: _ageFilter,
                tooltip: '年齢制限フィルタ',
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                onSelected: (val) {
                  setState(() {
                    _ageFilter = val;
                  });
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: _AgeFilter.all,
                    child: Text('すべて表示 (全年齢 + R-18)'),
                  ),
                  const PopupMenuItem(
                    value: _AgeFilter.r18Only,
                    child: Text('R-18 / R-18G のみ'),
                  ),
                  const PopupMenuItem(
                    value: _AgeFilter.safeOnly,
                    child: Text('全年齢のみ'),
                  ),
                ],
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _ageFilter != _AgeFilter.all
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).dividerColor,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.filter_list,
                        size: 16,
                        color: _ageFilter != _AgeFilter.all
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _ageFilterLabel(_ageFilter),
                        style: TextStyle(
                          fontSize: 12,
                          color: _ageFilter != _AgeFilter.all
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _subTabController,
            children: [
              _NovelKeywordRankingList(
                word: widget.word,
                isDaily: true,
                ageFilter: _ageFilter,
              ),
              _NovelKeywordRankingList(
                word: widget.word,
                isDaily: false,
                ageFilter: _ageFilter,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _NovelKeywordRankingList extends StatefulWidget {
  final String word;
  final bool isDaily;
  final _AgeFilter ageFilter;

  const _NovelKeywordRankingList({
    Key? key,
    required this.word,
    required this.isDaily,
    required this.ageFilter,
  }) : super(key: key);

  @override
  State<_NovelKeywordRankingList> createState() =>
      _NovelKeywordRankingListState();
}

class _NovelKeywordRankingListState extends State<_NovelKeywordRankingList>
    with AutomaticKeepAliveClientMixin {
  late EasyRefreshController _refreshController;
  final Map<int, Novel> _novelMap = {};
  List<NovelStore> _rankedStores = [];
  String? _scanNextUrl;
  bool _isLoading = true;
  String? _errorMessage;
  String _periodInfo = '';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _refreshController = EasyRefreshController(
      controlFinishLoad: true,
      controlFinishRefresh: true,
    );
    _fetchRanking();
  }

  @override
  void didUpdateWidget(covariant _NovelKeywordRankingList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.word != widget.word || oldWidget.isDaily != widget.isDaily) {
      _fetchRanking();
    } else if (oldWidget.ageFilter != widget.ageFilter) {
      setState(() {
        _rebuildSortedList();
      });
    }
  }

  @override
  void dispose() {
    _refreshController.dispose();
    super.dispose();
  }

  void _mergeNovels(List<Novel> list) {
    for (final n in list) {
      if (n.hateByUser()) continue;
      final existing = _novelMap[n.id];
      if (existing == null || n.totalBookmarks >= existing.totalBookmarks) {
        _novelMap[n.id] = n;
      }
    }
  }

  bool _matchesAgeFilter(Novel n) {
    switch (widget.ageFilter) {
      case _AgeFilter.all:
        return true;
      case _AgeFilter.r18Only:
        if (n.xRestrict > 0 || n.isXRestricted) return true;
        return n.tags.any(
          (t) =>
              t.name.toUpperCase().contains('R-18') ||
              t.name.toUpperCase().contains('R18'),
        );
      case _AgeFilter.safeOnly:
        if (n.xRestrict > 0 || n.isXRestricted) return false;
        return !n.tags.any(
          (t) =>
              t.name.toUpperCase().contains('R-18') ||
              t.name.toUpperCase().contains('R18'),
        );
    }
  }

  void _rebuildSortedList() {
    final filtered = _novelMap.values.where(_matchesAgeFilter).toList();
    if (widget.isDaily) {
      final now = DateTime.now();
      filtered.sort((a, b) {
        final aHours = now.difference(a.createDate).inHours.clamp(1, 24 * 365);
        final bHours = now.difference(b.createDate).inHours.clamp(1, 24 * 365);
        final aRecent = aHours <= 72;
        final bRecent = bHours <= 72;
        if (aRecent != bRecent && filtered.where((x) => now.difference(x.createDate).inHours <= 72).length >= 5) {
          return aRecent ? -1 : 1;
        }
        final cmp = b.totalBookmarks.compareTo(a.totalBookmarks);
        if (cmp != 0) return cmp;
        return b.totalView.compareTo(a.totalView);
      });
    } else {
      filtered.sort((a, b) {
        final cmp = b.totalBookmarks.compareTo(a.totalBookmarks);
        if (cmp != 0) return cmp;
        return b.totalView.compareTo(a.totalView);
      });
    }
    _rankedStores =
        filtered.map((n) => NovelStore(n.id, n)).toList(growable: false);
  }

  Future<NovelRecomResponse?> _safeFetch(Future<Response> Function() call) async {
    try {
      final res = await call();
      if (res.statusCode == 200 && res.data != null) {
        return NovelRecomResponse.fromJson(res.data);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _fetchRanking() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = null;
      _novelMap.clear();
      _scanNextUrl = null;
    });

    try {
      if (widget.isDaily) {
        await _fetchDailyRanking();
      } else {
        await _fetchOverallRanking();
      }

      if (!mounted) return;
      setState(() {
        _rebuildSortedList();
        _isLoading = false;
      });
      _refreshController.finishRefresh(IndicatorResult.success);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
      _refreshController.finishRefresh(IndicatorResult.fail);
    }
  }

  /// 日刊ランキングの取得（プレミアム不要：直近24時間〜7日間の作品を自動収集してブクマ・閲覧数順にランキング化）
  Future<void> _fetchDailyRanking() async {
    final now = DateTime.now();
    final day1 = now.subtract(const Duration(days: 1));
    final day3 = now.subtract(const Duration(days: 3));
    final day7 = now.subtract(const Duration(days: 7));

    final results = await Future.wait([
      _safeFetch(
        () => apiClient.getSearchNovel(
          widget.word,
          sort: 'date_desc',
          start_date: day1,
          end_date: now,
        ),
      ),
      _safeFetch(
        () => apiClient.getSearchNovel(
          widget.word,
          sort: 'date_desc',
          start_date: day3,
          end_date: now,
        ),
      ),
      _safeFetch(
        () => apiClient.getSearchNovel(
          widget.word,
          sort: 'date_desc',
          start_date: day7,
          end_date: now,
        ),
      ),
    ]);

    final r1 = results[0];
    final r3 = results[1];
    final r7 = results[2];

    if (r1 != null && r1.novels.length >= 10) {
      _mergeNovels(r1.novels);
      _scanNextUrl = r1.nextUrl;
      _periodInfo = '直近24時間の人気ランキング';
    } else if (r3 != null && r3.novels.length >= 10) {
      if (r1 != null) _mergeNovels(r1.novels);
      _mergeNovels(r3.novels);
      _scanNextUrl = r3.nextUrl;
      _periodInfo = '直近3日間の日刊・新着人気ランキング';
    } else {
      if (r1 != null) _mergeNovels(r1.novels);
      if (r3 != null) _mergeNovels(r3.novels);
      if (r7 != null) {
        _mergeNovels(r7.novels);
        _scanNextUrl = r7.nextUrl;
      }
      if (_novelMap.length < 15) {
        final latest = await _safeFetch(
          () => apiClient.getSearchNovel(widget.word, sort: 'date_desc'),
        );
        if (latest != null) {
          _mergeNovels(latest.novels);
          _scanNextUrl = latest.nextUrl;
        }
        _periodInfo = '直近新着の人気ランキング';
      } else {
        _periodInfo = '直近7日間の人気ランキング';
      }
    }

    // 初期表示をすぐに出す
    if (mounted && _novelMap.isNotEmpty) {
      setState(() {
        _rebuildSortedList();
        _isLoading = false;
      });
    }

    // さらに最大2ページ追加スキャンして日刊ランキングの精度を高める
    int extraPages = 0;
    while (_scanNextUrl != null &&
        _scanNextUrl!.isNotEmpty &&
        extraPages < 2 &&
        mounted) {
      extraPages++;
      final nextRes = await _safeFetch(() => apiClient.getNext(_scanNextUrl!));
      if (nextRes == null || nextRes.novels.isEmpty) break;
      _mergeNovels(nextRes.novels);
      _scanNextUrl = nextRes.nextUrl;
      if (mounted) {
        setState(() {
          _rebuildSortedList();
        });
      }
    }
  }

  /// 総合ランキングの取得（プレミアム不要：公式popular-preview ＋ users入りタグ横断 ＋ 複数ページ深掘り集計）
  Future<void> _fetchOverallRanking() async {
    _periodInfo = '全期間の総合人気ランキング（プレミアム不要）';

    final initialBatch = await Future.wait([
      _safeFetch(() => apiClient.getPopularPreviewNovel(widget.word)),
      _safeFetch(
        () => apiClient.getSearchNovel(widget.word, sort: 'popular_desc'),
      ),
      _safeFetch(
        () => apiClient.getSearchNovel('${widget.word} 10000users入り'),
      ),
      _safeFetch(
        () => apiClient.getSearchNovel('${widget.word} 5000users入り'),
      ),
      _safeFetch(
        () => apiClient.getSearchNovel('${widget.word} 1000users入り'),
      ),
      _safeFetch(
        () => apiClient.getSearchNovel('${widget.word} 500users入り'),
      ),
      _safeFetch(
        () => apiClient.getSearchNovel('${widget.word} 100users入り'),
      ),
      _safeFetch(
        () => apiClient.getSearchNovel(widget.word, sort: 'date_desc'),
      ),
    ]);

    for (int i = 0; i < initialBatch.length; i++) {
      final res = initialBatch[i];
      if (res != null) {
        _mergeNovels(res.novels);
        if (i == 7 && res.nextUrl != null) {
          _scanNextUrl = res.nextUrl;
        }
      }
    }

    // 第1弾が揃った時点で即座に画面に表示
    if (mounted && _novelMap.isNotEmpty) {
      setState(() {
        _rebuildSortedList();
        _isLoading = false;
      });
    }

    // 100users入り未満の中小規模タグでも正確に総合ランキングを作るため、新着を最大3ページ追加スキャン
    int extraPages = 0;
    while (_scanNextUrl != null &&
        _scanNextUrl!.isNotEmpty &&
        extraPages < 3 &&
        mounted) {
      extraPages++;
      final nextRes = await _safeFetch(() => apiClient.getNext(_scanNextUrl!));
      if (nextRes == null || nextRes.novels.isEmpty) break;
      _mergeNovels(nextRes.novels);
      _scanNextUrl = nextRes.nextUrl;
      if (mounted) {
        setState(() {
          _rebuildSortedList();
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_scanNextUrl == null || _scanNextUrl!.isEmpty) {
      _refreshController.finishLoad(IndicatorResult.noMore);
      return;
    }

    try {
      int loadedPages = 0;
      while (_scanNextUrl != null &&
          _scanNextUrl!.isNotEmpty &&
          loadedPages < 2) {
        loadedPages++;
        final nextRes = await _safeFetch(() => apiClient.getNext(_scanNextUrl!));
        if (nextRes == null || nextRes.novels.isEmpty) {
          _scanNextUrl = null;
          break;
        }
        _mergeNovels(nextRes.novels);
        _scanNextUrl = nextRes.nextUrl;
      }

      if (!mounted) return;
      setState(() {
        _rebuildSortedList();
      });
      _refreshController.finishLoad(
        (_scanNextUrl != null && _scanNextUrl!.isNotEmpty)
            ? IndicatorResult.success
            : IndicatorResult.noMore,
      );
    } catch (_) {
      _refreshController.finishLoad(IndicatorResult.fail);
    }
  }

  Widget _buildRankBadge(int rank) {
    Color bgColor;
    Color textColor;
    if (rank == 1) {
      bgColor = const Color(0xFFFFD700);
      textColor = Colors.black87;
    } else if (rank == 2) {
      bgColor = const Color(0xFFC0C0C0);
      textColor = Colors.black87;
    } else if (rank == 3) {
      bgColor = const Color(0xFFCD7F32);
      textColor = Colors.white;
    } else {
      bgColor = Theme.of(context).colorScheme.secondaryContainer;
      textColor = Theme.of(context).colorScheme.onSecondaryContainer;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '${rank}位',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: textColor,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_isLoading && _rankedStores.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null && _rankedStores.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(':(', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _fetchRanking,
              child: Text(I18n.of(context).retry),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: Text(_errorMessage!),
            ),
          ],
        ),
      );
    }

    if (_rankedStores.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book_outlined, size: 48, color: Colors.grey),
            const SizedBox(height: 8),
            const Text('該当する小説が見つかりませんでした'),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _fetchRanking,
              child: const Text('再読み込み'),
            ),
          ],
        ),
      );
    }

    return EasyRefresh(
      controller: _refreshController,
      header: PixezDefault.header(context),
      onRefresh: _fetchRanking,
      onLoad: _loadMore,
      child: ListView.builder(
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: _rankedStores.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12.0,
                vertical: 6.0,
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _periodInfo,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                  Text(
                    '${_rankedStores.length}件集計済',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ],
              ),
            );
          }

          final rank = index;
          final storeItem = _rankedStores[index - 1];
          final Novel novel = storeItem.novel!;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0, vertical: 2.0),
            child: InkWell(
              onTap: () {
                Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute(
                    builder: (BuildContext context) => NovelViewerPage(
                      id: novel.id,
                      novelStore: storeItem,
                    ),
                  ),
                );
              },
              child: Card(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      flex: 5,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 8.0,
                              horizontal: 4.0,
                            ),
                            child: Stack(
                              children: [
                                PixivImage(novel.imageUrls.medium, width: 80),
                                Positioned(
                                  top: 2,
                                  left: 2,
                                  child: _buildRankBadge(rank),
                                ),
                              ],
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(
                                    top: 8.0,
                                    left: 8.0,
                                  ),
                                  child: Text(
                                    novel.title,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodyLarge,
                                    maxLines: 3,
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8.0,
                                    vertical: 2.0,
                                  ),
                                  child: Wrap(
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    spacing: 8,
                                    children: [
                                      Text(
                                        novel.user.name,
                                        maxLines: 1,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall!
                                            .copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .secondary,
                                            ),
                                      ),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.article,
                                            size: 12,
                                            color: Theme.of(context)
                                                .textTheme
                                                .labelSmall!
                                                .color,
                                          ),
                                          const SizedBox(width: 2),
                                          Text(
                                            '${novel.textLength}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall,
                                          ),
                                        ],
                                      ),
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.visibility,
                                            size: 12,
                                            color: Theme.of(context)
                                                .textTheme
                                                .labelSmall!
                                                .color,
                                          ),
                                          const SizedBox(width: 2),
                                          Text(
                                            '${novel.totalView}',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall,
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 8.0,
                                  ),
                                  child: Wrap(
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    spacing: 3,
                                    runSpacing: 0,
                                    children: [
                                      for (var f in novel.tags)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 1,
                                          ),
                                          child: Text(
                                            f.name,
                                            style: Theme.of(context)
                                                .textTheme
                                                .bodySmall
                                                ?.copyWith(
                                                  color: (f.name == 'R-18' ||
                                                          f.name == 'R-18G')
                                                      ? Colors.redAccent
                                                      : null,
                                                  fontWeight: (f.name ==
                                                              'R-18' ||
                                                          f.name == 'R-18G')
                                                      ? FontWeight.bold
                                                      : null,
                                                ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 8.0),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      flex: 1,
                      child: Column(
                        mainAxisSize: MainAxisSize.max,
                        children: [
                          NovelBookmarkButton(novel: novel),
                          Text(
                            '${novel.totalBookmarks}',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
