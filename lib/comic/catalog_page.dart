import 'site_directory_pane.dart';
import 'site_rules_page.dart';
import 'rule_browse_page.dart';
import 'services/site_rule_store.dart';
import 'services/last_opened_site_store.dart';
import 'list_rule_lab_page.dart';
import 'saved_downloads_page.dart';
import 'chapter_read_state_widgets.dart';
import 'services/chapter_read_state_store.dart';
import 'chapter_details.dart';
import 'chapter_order.dart';
import 'favorite_updates_page.dart';
import 'cover_widgets.dart';
import 'library_widgets.dart';
import 'rule_library_widgets.dart';
import 'services/rule_library.dart';
import 'services/user_library_store.dart';
import 'package:flutter/material.dart';

import 'chapter_reader_page.dart';
import 'services/download_store.dart';
import 'sources/source_adapter.dart';

class SourceHome extends StatefulWidget {
  const SourceHome({super.key, required this.adapter, required this.store});

  final SourceAdapter adapter;
  final DownloadStore store;

  @override
  State<SourceHome> createState() => _SourceHomeState();
}

class _SourceHomeState extends State<SourceHome> {
  SavedSiteRule? _activeSite;
  List<SavedSiteRule> _savedSites = [];
  bool _sitesBusy = false;
  String? _sitesError;

  LastOpenedSiteStore get _lastSiteStore =>
      LastOpenedSiteStore(widget.store.root);

  Future<void> _initializeHome() async {
    // 最初に選択サイトを復元する。
    // 復元が終わるまでは作品一覧の取得を開始しない。
    final remembered = await _lastSiteStore.read();

    try {
      final sites = await SiteRuleStore(widget.store.root).load();
      if (!mounted) return;

      _savedSites = sites;

      if (remembered == LastOpenedSiteStore.builtinSiteId) {
        _activeSite = null;
        _section = 0;
      } else {
        SavedSiteRule? selected;

        for (final site in sites) {
          if (site.id == remembered && site.rules.containsKey('works')) {
            selected = site;
            break;
          }
        }

        _activeSite = selected;
        _section = selected == null ? 4 : 0;
      }
    } catch (error) {
      if (!mounted) return;
      _sitesError = 'サイト一覧を読み込めませんでした：$error';
      _section = 4;
    }

    if (!mounted) return;
    await _restoreTabs();
  }

  Future<void> _reloadSiteDirectory({bool restoreSelection = false}) async {
    if (_sitesBusy) return;

    setState(() {
      _sitesBusy = true;
      _sitesError = null;
    });

    try {
      final sites = await SiteRuleStore(widget.store.root).load();
      final remembered = restoreSelection ? await _lastSiteStore.read() : null;

      if (!mounted) return;

      setState(() {
        _savedSites = sites;

        if (restoreSelection &&
            remembered == LastOpenedSiteStore.builtinSiteId) {
          _activeSite = null;
        } else {
          final wantedId = restoreSelection && remembered != null
              ? remembered
              : _activeSite?.id;

          SavedSiteRule? selected;

          for (final site in sites) {
            if (site.id == wantedId && site.rules.containsKey('works')) {
              selected = site;
              break;
            }
          }

          if (wantedId != null) {
            _activeSite = selected;

            if (selected == null && _section == 0) {
              _section = 4;
            }
          }
        }
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _sitesError = 'サイト一覧を読み込めませんでした：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _sitesBusy = false);
    }
  }

  Future<void> _selectSite(SavedSiteRule? site) async {
    if (_loading) return;

    if (site != null && !site.rules.containsKey('works')) {
      await _openSiteManager(site);
      return;
    }

    setState(() {
      _activeSite = site;
      _section = 0;
    });

    try {
      await _lastSiteStore.write(site?.id ?? LastOpenedSiteStore.builtinSiteId);
    } catch (_) {
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '起動サイトを保存できませんでした。'
            '次回起動時に元のサイトへ戻る場合があります。',
          ),
        ),
      );
    }
  }

  Future<void> _openSiteManager([SavedSiteRule? site]) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            SiteRulesPage(store: widget.store, initialSiteId: site?.id),
      ),
    );

    if (!mounted) return;
    await _reloadSiteDirectory(restoreSelection: true);
  }

  Future<void> _openRuleLab() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ListRuleLabPage(
          store: widget.store,
          initialPage: null,
          initialUrl: 'https://',
          initialSelector: '',
          initialAcquisition: 'staticHtml',
        ),
      ),
    );

    if (!mounted) return;
    await _reloadSiteDirectory(restoreSelection: true);
  }

  void _changeHomeSection(int navigationIndex) {
    // 既存の棚の内部番号を維持し、表示順だけ変更する。
    const sections = [0, 4, 1, 2, 3];

    setState(() => _section = sections[navigationIndex]);

    if (_section == 4) {
      _reloadSiteDirectory();
    }
  }

  int _section = 4;
  late List<SourceTab> _tabs;
  List<SourceTab> _knownTabs = [];
  bool _loading = true;

  String get _settingsKey => '${widget.adapter.id}:tab-settings';

  @override
  void initState() {
    super.initState();
    _tabs = widget.adapter.defaultTabs;
    _knownTabs = List.of(_tabs);
    _initializeHome();
  }

  Future<void> _restoreTabs() async {
    final cached = await widget.store.readCache(_settingsKey);

    try {
      if (cached is Map) {
        final selected = (cached['selected'] as List)
            .map(
              (item) =>
                  SourceTab.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList();

        final known = (cached['known'] as List)
            .map(
              (item) =>
                  SourceTab.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList();

        if (selected.isNotEmpty) {
          _tabs = selected;
          _knownTabs = known;
        }
      }
    } catch (_) {
      // 設定が不正ならアダプターの初期タブを使用する。
    }

    if (mounted) setState(() => _loading = false);
  }

  Future<void> _addTab() async {
    setState(() => _loading = true);

    try {
      _knownTabs = await widget.adapter.discoverTabs();
    } catch (_) {
      // オフラインなら以前取得した候補を使う。
    }

    if (!mounted) return;
    setState(() => _loading = false);

    final candidates = _knownTabs
        .where((item) => !_tabs.any((tab) => tab.id == item.id))
        .toList();

    if (candidates.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('追加候補がありません。必要に応じてネット接続を確認してください。')),
      );
      return;
    }

    final chosen = await showDialog<SourceTab>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('タブを追加'),
        children: [
          for (final candidate in candidates)
            SimpleDialogOption(
              onPressed: () {
                Navigator.pop(dialogContext, candidate);
              },
              child: Text(candidate.title),
            ),
        ],
      ),
    );

    if (chosen == null || !mounted) return;

    setState(() => _tabs = [..._tabs, chosen]);

    try {
      await widget.store.writeCache(_settingsKey, {
        'selected': _tabs.map((item) => item.toJson()).toList(),
        'known': _knownTabs.map((item) => item.toJson()).toList(),
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('タブ設定を保存できませんでした')));
    }
  }

  Future<void> _openFavorite(LibraryItem item) async {
    if (isRuleLibrarySource(item.sourceId)) {
      await openRuleLibraryItem(
        context: context,
        store: widget.store,
        item: item,
        history: false,
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChapterListPage(
          adapter: widget.adapter,
          store: widget.store,
          tab: item.tab,
          work: item.work,
        ),
      ),
    );
  }

  Future<void> _openHistory(LibraryItem item) async {
    if (isRuleLibrarySource(item.sourceId)) {
      await openRuleLibraryItem(
        context: context,
        store: widget.store,
        item: item,
        history: true,
      );
      return;
    }
    final chapter = item.chapter;
    if (chapter == null) return;

    final cacheKey =
        '${widget.adapter.id}:chapters:'
        '${item.tab.query.toJson()}:${item.work.id}';

    final chapters = <ComicChapter>[];
    final cached = await widget.store.readCache(cacheKey);

    if (cached is List) {
      for (final entry in cached) {
        try {
          final parsed = ComicChapter.fromJson(
            Map<String, dynamic>.from(entry as Map),
          );

          if (parsed.sourceId == widget.adapter.id &&
              parsed.language == item.tab.query.language &&
              parsed.workId == item.work.id) {
            chapters.add(parsed);
          }
        } catch (_) {
          // 読める項目を優先。
        }
      }
    }

    if (chapters.isEmpty) {
      try {
        chapters.addAll(
          await widget.adapter.fetchChapters(item.work, item.tab.query),
        );
      } catch (_) {
        // オフラインでも、履歴の話だけは開けるようにする。
      }
    }

    var index = chapters.indexWhere((entry) => entry.id == chapter.id);

    if (index < 0) {
      chapters
        ..clear()
        ..add(chapter);
      index = 0;
    }

    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChapterReaderPage(
          adapter: widget.adapter,
          store: widget.store,
          chapters: List.unmodifiable(chapters),
          initialIndex: (index),
          onChapterOpened: (opened) => UserLibraryStore.forRoot(
            widget.store.root,
          ).remember(widget.adapter.id, item.tab, item.work, opened),
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.adapter.close();
    widget.store.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final customDiscovery = _section == 0 && _activeSite != null;

    final title = switch (_section) {
      1 => 'お気に入り',
      2 => '閲覧履歴',
      3 => '保存済み',
      4 => 'サイト一覧',
      _ => _activeSite?.name ?? widget.adapter.name,
    };

    const sections = [0, 4, 1, 2, 3];

    return DefaultTabController(
      key: ValueKey(_tabs.map((item) => item.id).join('|')),
      length: _tabs.length,
      child: Scaffold(
        backgroundColor: Colors.black,

        // 独自サイト側のAppBarを使い、上部バーの二重表示を避ける。
        appBar: customDiscovery
            ? null
            : AppBar(
                backgroundColor: Colors.black,
                title: Text(title),
                actions: [
                  if (_section == 0 || _section == 4)
                    IconButton(
                      tooltip: '新規サイトルール作成',
                      onPressed: _loading ? null : _openRuleLab,
                      icon: const Icon(Icons.add_circle_outline),
                    ),
                  if (_section == 4)
                    IconButton(
                      tooltip: 'サイト一覧を更新',
                      onPressed: _loading || _sitesBusy
                          ? null
                          : () => _reloadSiteDirectory(),
                      icon: const Icon(Icons.refresh),
                    ),
                  if (_section == 1)
                    TextButton.icon(
                      onPressed: () {
                        Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) => FavoriteUpdatesPage(
                              adapter: widget.adapter,
                              store: widget.store,
                              library: UserLibraryStore.forRoot(
                                widget.store.root,
                              ),
                            ),
                          ),
                        );
                      },
                      icon: const Icon(Icons.fiber_new_outlined),
                      label: const Text('新着'),
                    ),
                  if (_section == 0 && _activeSite == null)
                    IconButton(
                      tooltip: '言語タブを追加',
                      onPressed: _loading ? null : _addTab,
                      icon: const Icon(Icons.add),
                    ),
                ],
                bottom: _section == 0 && _activeSite == null
                    ? TabBar(
                        isScrollable: true,
                        tabs: [for (final tab in _tabs) Tab(text: tab.title)],
                      )
                    : null,
              ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : IndexedStack(
                index: _section,
                children: [
                  // サイト一覧表示中などは、未表示サイトの通信を始めない。
                  _activeSite != null
                      ? (_section == 0
                            ? RuleBrowsePage(
                                key: ValueKey(
                                  'home-site:${_activeSite!.id}:'
                                  '${_activeSite!.updatedAt.toIso8601String()}',
                                ),
                                site: _activeSite!,
                              )
                            : const SizedBox.shrink())
                      : (_section == 0
                            ? TabBarView(
                                children: [
                                  for (final tab in _tabs)
                                    WorkListPage(
                                      key: ValueKey(tab.id),
                                      adapter: widget.adapter,
                                      store: widget.store,
                                      tab: tab,
                                    ),
                                ],
                              )
                            : const SizedBox.shrink()),
                  LibraryShelf(
                    library: UserLibraryStore.forRoot(widget.store.root),
                    sourceId: widget.adapter.id,
                    sourceName: widget.adapter.name,
                    includeCustomSites: true,
                    history: false,
                    onOpen: _openFavorite,
                  ),
                  LibraryShelf(
                    library: UserLibraryStore.forRoot(widget.store.root),
                    sourceId: widget.adapter.id,
                    sourceName: widget.adapter.name,
                    includeCustomSites: true,
                    history: true,
                    onOpen: _openHistory,
                  ),
                  SavedDownloadsPane(
                    adapter: widget.adapter,
                    store: widget.store,
                    active: _section == 3,
                  ),
                  SiteDirectoryPane(
                    sites: _savedSites,
                    activeSiteId: _activeSite?.id,
                    busy: _sitesBusy,
                    error: _sitesError,
                    onOpen: (site) => _selectSite(site),
                    onManage: (site) => _openSiteManager(site),
                    onLab: _openRuleLab,
                    onRefresh: () => _reloadSiteDirectory(),
                  ),
                ],
              ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: sections.indexOf(_section),
          onTap: _loading ? null : _changeHomeSection,
          type: BottomNavigationBarType.fixed,
          backgroundColor: const Color(0xFF1A1A1A),
          selectedItemColor: Colors.lightBlueAccent,
          unselectedItemColor: Colors.white54,
          selectedFontSize: 12,
          unselectedFontSize: 12,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.grid_view), label: '発見'),
            BottomNavigationBarItem(icon: Icon(Icons.language), label: 'サイト'),
            BottomNavigationBarItem(
              icon: Icon(Icons.star_border),
              activeIcon: Icon(Icons.star),
              label: 'お気に入り',
            ),
            BottomNavigationBarItem(icon: Icon(Icons.history), label: '履歴'),
            BottomNavigationBarItem(
              icon: Icon(Icons.download_done),
              label: '保存済み',
            ),
          ],
        ),
      ),
    );
  }
}

class WorkListPage extends StatefulWidget {
  const WorkListPage({
    super.key,
    required this.adapter,
    required this.store,
    required this.tab,
  });

  final SourceAdapter adapter;
  final DownloadStore store;
  final SourceTab tab;

  @override
  State<WorkListPage> createState() => _WorkListPageState();
}

class _WorkListPageState extends State<WorkListPage>
    with AutomaticKeepAliveClientMixin {
  List<ComicWork> _works = [];
  bool _busy = true;
  String? _error;

  String get _cacheKey =>
      '${widget.adapter.id}:works:${widget.tab.query.toJson()}';

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    final cached = await widget.store.readCache(_cacheKey);

    try {
      if (cached is List) {
        _works = cached
            .map(
              (item) =>
                  ComicWork.fromJson(Map<String, dynamic>.from(item as Map)),
            )
            .toList();
      }
    } catch (_) {
      _works = [];
    }

    if (_works.isEmpty) {
      _works = widget.adapter.fallbackWorks(widget.tab.query);
    }

    if (!mounted) return;
    setState(() => _busy = false);

    // 初回、または明示更新時に公式ページから画像などを取得。
    if (cached == null) await _refresh();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final works = await widget.adapter.fetchWorks(widget.tab.query);

      await widget.store.writeCache(
        _cacheKey,
        works.map((item) => item.toJson()).toList(),
      );

      if (!mounted) return;
      setState(() => _works = works);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '更新できませんでした：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _placeholder() => const ColoredBox(
    color: Color(0xFF252525),
    child: Center(
      child: Icon(Icons.collections_bookmark_outlined, color: Colors.white38),
    ),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);

    return Column(
      children: [
        SizedBox(
          height: 48,
          child: Row(
            children: [
              const SizedBox(width: 12),
              Text('${_works.length}作品'),
              const Spacer(),
              TextButton.icon(
                onPressed: _busy ? null : _refresh,
                icon: const Icon(Icons.refresh),
                label: const Text('更新'),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 3,
          child: _busy
              ? const LinearProgressIndicator(minHeight: 3)
              : const SizedBox.expand(),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(8),
            child: Text(_error!, style: const TextStyle(color: Colors.white60)),
          ),
        Expanded(
          child: CoverGrid<ComicWork>(
            items: _works,
            workOf: (work) => work,
            placeholderBuilder: _placeholder,
            onOpen: (work) {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChapterListPage(
                    adapter: widget.adapter,
                    store: widget.store,
                    tab: widget.tab,
                    work: work,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class ChapterListPage extends StatefulWidget {
  const ChapterListPage({
    super.key,
    required this.adapter,
    required this.store,
    required this.tab,
    required this.work,
  });

  final SourceAdapter adapter;
  final DownloadStore store;
  final SourceTab tab;
  final ComicWork work;

  @override
  State<ChapterListPage> createState() => _ChapterListPageState();
}

class _ChapterListPageState extends State<ChapterListPage> {
  ChapterReadStateStore get _readStates =>
      ChapterReadStateStore.forRoot(widget.store.root);

  Future<void> _changeReadState(
    ComicChapter chapter,
    ChapterReadState next,
  ) async {
    if (_locked) return;
    setState(() => _busy = true);

    try {
      await _readStates.setChapterState(chapter, next);

      if (mounted) {
        setState(() {
          _status = next == ChapterReadState.completed
              ? '読了にしました：${chapter.title}'
              : '未読に戻しました：${chapter.title}';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = '読書状態を保存できませんでした。\n$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _lastOpenedChapterId;
  bool _readingEntryReady = false;
  String? _readingEntryError;

  UserLibraryStore get _readingLibrary =>
      UserLibraryStore.forRoot(widget.store.root);

  void _syncReadingEntry() {
    if (!mounted) return;

    String? latest;

    for (final item in _readingLibrary.history) {
      if (item.sourceId == widget.adapter.id &&
          item.tab.query.language == widget.tab.query.language &&
          item.work.id == widget.work.id) {
        latest = item.chapter?.id;
        break;
      }
    }

    setState(() {
      _lastOpenedChapterId = latest;
      _readingEntryReady = true;
      _readingEntryError = null;
    });
  }

  Future<void> _loadReadingEntry() async {
    try {
      await _readingLibrary.load();
      _syncReadingEntry();
    } catch (error) {
      if (!mounted) return;

      setState(() {
        _readingEntryError = '履歴を読み込めませんでした：$error';
      });
    }
  }

  Widget _readingEntryButton() {
    final target = readingEntryChapter(_chapters, _lastOpenedChapterId);

    final hasHistory = _lastOpenedChapterId != null;
    final error = _readingEntryError;

    final String title;
    final String detail;

    if (error != null) {
      title = '履歴の再読み込み';
      detail = '履歴の読み込みに失敗しました';
    } else if (!_readingEntryReady) {
      title = '読書履歴を読み込み中';
      detail = 'しばらくお待ちください';
    } else if (hasHistory && target == null) {
      title = '前回の話が一覧にありません';
      detail = '一覧を更新するか、読みたい話を選んでください';
    } else {
      title = hasHistory ? '続きから読む' : '最初の話を読む';
      detail = target?.title ?? 'チャプターがありません';
    }

    final buttonHeight =
        (MediaQuery.textScalerOf(context).scale(14) * 1.4 * 2).ceilToDouble() +
        28;

    return SizedBox(
      height: buttonHeight,
      child: Tooltip(
        message: error ?? '$title\n$detail',
        child: FilledButton.icon(
          onPressed: _locked
              ? null
              : error != null
              ? _loadReadingEntry
              : !_readingEntryReady || target == null
              ? null
              : () => _open(target),
          icon: const Icon(Icons.play_arrow),
          label: SizedBox(
            width: double.infinity,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.4,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _chapterLabels(
    ComicChapter chapter,
    bool saved,
    double titleHeight,
    double subtitleHeight,
    double dateHeight,
  ) {
    final previous = chapter.id == _lastOpenedChapterId;
    final readStateHeight =
        (MediaQuery.textScalerOf(context).scale(12) * 1.4).ceilToDouble() + 4;

    final status = [
      saved ? '保存済み・オフライン閲覧可能' : 'オンラインで読む',
      if (previous) '前回開いた話',
    ].join('・');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: titleHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              chapter.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, height: 1.3),
            ),
          ),
        ),
        SizedBox(
          height: subtitleHeight,
          child: Tooltip(
            message: status,
            child: Text(
              status,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                height: 1.3,
                color: previous
                    ? Colors.lightBlueAccent
                    : saved
                    ? Colors.tealAccent
                    : Colors.white54,
              ),
            ),
          ),
        ),
        SizedBox(
          height: readStateHeight,
          child: ChapterReadStatus(store: _readStates, chapter: chapter),
        ),
        SizedBox(
          height: dateHeight,
          child: Tooltip(
            message: chapterDateLabel(chapter),
            child: Text(
              chapterDateLabel(chapter),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12,
                height: 1.4,
                color: Colors.white54,
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool _chapterDescending = false;
  bool _sortChanging = false;

  final ScrollController _chapterListController = ScrollController();

  String get _sortCacheKey => chapterSortCacheKey(
    sourceId: widget.adapter.id,
    language: widget.tab.query.language,
    workId: widget.work.id,
  );

  Future<void> _restoreChapterSort() async {
    final saved = await widget.store.readCache(_sortCacheKey);
    _chapterDescending = saved is Map && saved['descending'] == true;
  }

  Future<void> _setChapterDescending(bool descending) async {
    if (_locked || descending == _chapterDescending) return;

    setState(() => _sortChanging = true);

    try {
      await widget.store.writeCache(_sortCacheKey, {'descending': descending});

      if (!mounted) return;

      setState(() => _chapterDescending = descending);

      if (_chapterListController.hasClients) {
        _chapterListController.jumpTo(0);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = '並び順を保存できませんでした。\n$error';
        });
      }
    } finally {
      if (mounted) setState(() => _sortChanging = false);
    }
  }

  @override
  void dispose() {
    _readingLibrary.removeListener(_syncReadingEntry);
    _chapterListController.dispose();
    super.dispose();
  }

  List<ComicChapter> _chapters = [];
  Set<String> _saved = {};

  bool _busy = true;
  bool _batch = false;
  bool _stop = false;
  String _status = '';

  bool get _locked => _busy || _batch || _sortChanging;

  String get _cacheKey =>
      '${widget.adapter.id}:chapters:${widget.tab.query.toJson()}:${widget.work.id}';

  bool _matches(ComicChapter chapter) =>
      chapter.sourceId == widget.adapter.id &&
      chapter.language == widget.tab.query.language &&
      chapter.workId == widget.work.id;

  @override
  void initState() {
    super.initState();
    _readingLibrary.addListener(_syncReadingEntry);
    _loadReadingEntry();
    _initialize();
  }

  Future<void> _initialize() async {
    await _restoreChapterSort();
    if (!mounted) return;

    final entries = <String, ComicChapter>{};
    final cached = await widget.store.readCache(_cacheKey);

    if (cached is List) {
      for (final item in cached) {
        try {
          final chapter = ComicChapter.fromJson(
            Map<String, dynamic>.from(item as Map),
          );
          if (_matches(chapter)) entries[chapter.id] = chapter;
        } catch (_) {
          // 不正な項目だけを無視。
        }
      }
    }

    try {
      for (final chapter in await widget.store.localChapters(widget.adapter)) {
        if (_matches(chapter)) {
          entries.putIfAbsent(chapter.id, () => chapter);
        }
      }
    } catch (_) {
      // 読める一覧を優先して表示する。
    }

    if (!mounted) return;
    _chapters = entries.values.toList()..sort((a, b) => a.id.compareTo(b.id));

    await _checkSaved();
    if (!mounted) return;
    setState(() => _busy = false);

    if (cached == null) await _refresh();
  }

  Future<void> _checkSaved() async {
    final saved = <String>{};

    for (final chapter in _chapters) {
      try {
        if ((await widget.store.load(chapter)).isNotEmpty) {
          saved.add(chapter.id);
        }
      } catch (_) {
        // 不完全な話は保存済みにしない。
      }
    }

    if (!mounted) return;
    setState(() {
      _saved = saved;
      _status = '${_chapters.length}件・${saved.length}件保存済み';
    });
  }

  Future<void> _refresh() async {
    if (_locked) return;
    setState(() {
      _busy = true;
      _status = 'チャプター一覧を取得中…';
    });

    try {
      final chapters = await widget.adapter.fetchChapters(
        widget.work,
        widget.tab.query,
      );

      await widget.store.writeCache(
        _cacheKey,
        chapters.map((item) => item.toJson()).toList(),
      );

      if (!mounted) return;
      _chapters = chapters;
      await _checkSaved();
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '一覧更新に失敗しました。\n$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(ComicChapter chapter) async {
    if (_locked) return;

    final index = _chapters.indexWhere((item) => item.id == chapter.id);

    if (index < 0) return;

    setState(() => _busy = true);

    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChapterReaderPage(
            adapter: widget.adapter,
            store: widget.store,
            chapters: List<ComicChapter>.unmodifiable(_chapters),
            initialIndex: index,
            onChapterOpened: (opened) => UserLibraryStore.forRoot(
              widget.store.root,
            ).remember(widget.adapter.id, widget.tab, widget.work, opened),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(ComicChapter chapter) async {
    try {
      if ((await widget.store.load(chapter)).isNotEmpty) {
        return;
      }
    } catch (_) {
      // 不完全な場合は再保存。
    }

    final content = await widget.adapter.fetchContent(chapter);

    await widget.store.download(chapter, content, (done, total) {
      if (!mounted) return;
      setState(() {
        _status = '${chapter.title}\n$done / $total ページ保存中';
      });
    });
  }

  Future<void> _download(ComicChapter chapter) async {
    if (_locked) return;
    setState(() => _busy = true);

    try {
      await _save(chapter);
    } catch (error) {
      _message('保存に失敗しました。\n$error');
    } finally {
      if (mounted) {
        await _checkSaved();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<bool> _confirm(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('キャンセル'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('実行'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _downloadAll() async {
    if (_locked) return;

    final targets = _chapters
        .where((chapter) => !_saved.contains(chapter.id))
        .toList();

    if (targets.isEmpty) {
      _message('表示中のチャプターはすべて保存済みです');
      return;
    }

    final confirmed = await _confirm(
      '一括ダウンロード',
      '${widget.tab.title}の「${widget.work.title}」から、'
          '未保存${targets.length}件を順番に保存します。\n\n'
          '通信量と空き容量にご注意ください。',
    );

    if (!confirmed || !mounted) return;

    setState(() {
      _batch = true;
      _stop = false;
    });

    var completed = 0;
    final failed = <String>[];

    for (final chapter in targets) {
      if (!mounted || _stop) break;

      try {
        await _save(chapter);
        completed++;
      } catch (_) {
        failed.add(chapter.title);
      }

      if (mounted) {
        setState(() {
          _status =
              '今回保存$completed件・失敗${failed.length}件'
              '／対象${targets.length}件';
        });
      }

      if (!_stop) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    if (!mounted) return;
    await _checkSaved();
    if (!mounted) return;

    setState(() {
      _batch = false;
      _status =
          '${_stop ? "停止" : "完了"}：'
          '今回保存$completed件・失敗${failed.length}件';
    });

    if (failed.isNotEmpty) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('保存できなかったチャプター'),
          content: SingleChildScrollView(child: Text(failed.join('\n'))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('閉じる'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _delete(ComicChapter chapter) async {
    if (_locked) return;

    final confirmed = await _confirm(
      '保存データを削除',
      '${chapter.title}の保存画像を削除しますか？\n閲覧位置の記録は残ります。',
    );

    if (!confirmed || !mounted) return;
    setState(() => _busy = true);

    try {
      await widget.store.delete(chapter);
    } catch (error) {
      _message('削除できませんでした。\n$error');
    } finally {
      if (mounted) {
        await _checkSaved();
        if (mounted) setState(() => _busy = false);
      }
    }
  }

  Future<void> _credits(ComicChapter chapter) async {
    if (_locked) return;
    setState(() => _busy = true);

    String text;

    try {
      final saved = await widget.store.readCredits(chapter);
      if (saved != null) {
        text = saved;
      } else {
        final content = await widget.adapter.fetchContent(chapter);
        text = content.credits;
        await widget.store.rememberCredits(chapter, text);
      }
    } catch (_) {
      text = 'クレジットを取得できませんでした。\n出典: ${chapter.url}';
    }

    if (!mounted) return;
    setState(() => _busy = false);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('作品のクレジット'),
        content: SingleChildScrollView(child: SelectableText(text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // chapter-list-stable-layout-v1
  @override
  Widget build(BuildContext context) {
    final displayedChapters = chapterDisplayOrder(
      _chapters,
      descending: _chapterDescending,
    );

    final textScaler = MediaQuery.textScalerOf(context);

    // 文字サイズの設定に合わせて領域を確保し、
    // 内容が変化しても高さが変わらないようにする。
    final statusHeight = textScaler.scale(14) * 1.4 * 2 + 8;
    final titleHeight = textScaler.scale(16) * 1.3 * 2;
    final subtitleHeight = textScaler.scale(14) * 1.3;
    final dateHeight = (textScaler.scale(12) * 1.4).ceilToDouble() + 4;

    final readStateHeight = (textScaler.scale(12) * 1.4).ceilToDouble() + 4;

    final rowHeight =
        (titleHeight + subtitleHeight + readStateHeight + dateHeight + 24)
            .ceilToDouble() +
        8;

    return PopScope(
      canPop: !_locked,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${widget.work.title}・${widget.tab.title}'),
          actions: [
            PopupMenuButton<bool>(
              tooltip: _chapterDescending ? '並び順：降順' : '並び順：昇順',
              enabled: !_locked,
              initialValue: _chapterDescending,
              onSelected: _setChapterDescending,
              icon: Icon(
                _chapterDescending ? Icons.arrow_downward : Icons.arrow_upward,
              ),
              itemBuilder: (_) => [
                CheckedPopupMenuItem<bool>(
                  value: false,
                  checked: !_chapterDescending,
                  child: const Text('昇順・古い話から'),
                ),
                CheckedPopupMenuItem<bool>(
                  value: true,
                  checked: _chapterDescending,
                  child: const Text('降順・新しい話から'),
                ),
              ],
            ),
            FavoriteWorkButton(
              library: UserLibraryStore.forRoot(widget.store.root),
              sourceId: widget.adapter.id,
              tab: widget.tab,
              work: widget.work,
            ),
            IconButton(
              tooltip: 'チャプター一覧を更新',
              onPressed: _locked ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _readingEntryButton(),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: statusHeight,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Tooltip(
                        message: _status,
                        child: Text(
                          _status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14, height: 1.4),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: _batch
                          ? (_stop ? null : () => setState(() => _stop = true))
                          : (_locked || _chapters.isEmpty
                                ? null
                                : _downloadAll),
                      icon: Icon(
                        _batch ? Icons.stop : Icons.download_for_offline,
                      ),
                      label: Text(
                        _batch
                            ? (_stop ? '現在の話の処理後に停止します' : '一括保存を停止')
                            : '未保存を一括ダウンロード',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // バーを隠している間も、同じ高さを確保する。
            SizedBox(
              height: 4,
              child: _locked
                  ? const LinearProgressIndicator(minHeight: 4)
                  : const SizedBox.expand(),
            ),

            Expanded(
              child: ListView.builder(
                controller: _chapterListController,
                key: PageStorageKey<String>(
                  'chapters:${widget.adapter.id}:'
                  '${widget.tab.id}:${widget.work.id}',
                ),
                itemExtent: rowHeight,
                itemCount: displayedChapters.length,
                itemBuilder: (context, index) {
                  final chapter = displayedChapters[index];
                  final saved = _saved.contains(chapter.id);

                  return Material(
                    key: ValueKey(chapter.id),
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: _locked ? null : () => _open(chapter),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _chapterLabels(
                                chapter,
                                saved,
                                titleHeight,
                                subtitleHeight,
                                dateHeight,
                              ),
                            ),
                            const SizedBox(width: 8),

                            // 保存前後で、右側の領域を同じ幅・高さにする。
                            SizedBox(
                              width: 96,
                              height: 48,
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: IconButton(
                                      tooltip: saved ? '保存済み' : 'ダウンロード',
                                      onPressed: saved || _locked
                                          ? null
                                          : () => _download(chapter),
                                      icon: Icon(
                                        saved
                                            ? Icons.offline_pin
                                            : Icons.download,
                                        color: saved ? Colors.tealAccent : null,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: PopupMenuButton<String>(
                                      enabled: !_locked,
                                      onSelected: (value) {
                                        if (value == 'complete') {
                                          _changeReadState(
                                            chapter,
                                            ChapterReadState.completed,
                                          );
                                        } else if (value == 'unread') {
                                          _changeReadState(
                                            chapter,
                                            ChapterReadState.unread,
                                          );
                                        } else if (value == 'delete') {
                                          _delete(chapter);
                                        } else {
                                          _credits(chapter);
                                        }
                                      },
                                      itemBuilder: (_) => const [
                                        PopupMenuItem(
                                          value: 'complete',
                                          child: Text('読了にする'),
                                        ),
                                        PopupMenuItem(
                                          value: 'unread',
                                          child: Text('未読に戻す'),
                                        ),
                                        PopupMenuItem(
                                          value: 'credits',
                                          child: Text('クレジット'),
                                        ),
                                        PopupMenuItem(
                                          value: 'delete',
                                          child: Text('保存データを削除'),
                                        ),
                                      ],
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
            ),
          ],
        ),
      ),
    );
  }
}
