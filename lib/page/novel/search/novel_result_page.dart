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
  @override
  void initState() {
    super.initState();
    tagHistoryStore.insert(
      TagsPersist(
        name: widget.word,
        translatedName: widget.translatedName ?? "",
      ),
    );
  }

  void _openUserSearchSheet(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(title: Text('${widget.word} - ${I18n.of(context).painter}')),
          body: PainterList(
            futureGet: () => apiClient.getSearchUser(widget.word),
            isNovel: true,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.word),
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
            NovelResultList(word: widget.word),
            NovelKeywordRankingView(word: widget.word),
          ],
        ),
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
