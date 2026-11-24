import 'saved_videos_page.dart';
import 'incomplete_downloads_page.dart';
import 'package:flutter/material.dart';

import 'chapter_details.dart';
import 'chapter_read_state_widgets.dart';
import 'chapter_reader_page.dart';
import 'services/chapter_read_state_store.dart';
import 'services/download_store.dart';
import 'services/saved_download_repository.dart';
import 'services/user_library_store.dart';
import 'services/rule_library.dart';
import 'sources/source_adapter.dart';

Widget _localPreview(SavedChapter item, double width, double height) {
  Widget placeholder() => const ColoredBox(
    color: Color(0xFF252525),
    child: Center(child: Icon(Icons.menu_book, color: Colors.white38)),
  );

  return SizedBox(
    width: width,
    height: height,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: Image.file(
        item.files.first,
        fit: BoxFit.cover,
        cacheWidth: 160,
        errorBuilder: (_, error, stack) => placeholder(),
      ),
    ),
  );
}

class _SavedGroup {
  const _SavedGroup({
    required this.key,
    required this.work,
    required this.tab,
    required this.items,
    this.adapter,
  });

  final SourceAdapter? adapter;

  final String key;
  final ComicWork? work;
  final SourceTab tab;
  final List<SavedChapter> items;

  String get title => work?.title ?? items.first.chapter.workId;
  int get bytes => items.fold(0, (sum, item) => sum + item.bytes);
}

class SavedDownloadsPane extends StatefulWidget {
  const SavedDownloadsPane({
    super.key,
    required this.adapter,
    required this.store,
    required this.active,
  });

  final SourceAdapter adapter;
  final DownloadStore store;
  final bool active;

  @override
  State<SavedDownloadsPane> createState() => _SavedDownloadsPaneState();
}

class _SavedDownloadsPaneState extends State<SavedDownloadsPane> {
  List<_SavedGroup> _groups = [];
  List<String> _issues = [];
  bool _busy = false;
  String _status = '保存済みを開くと端末内のデータを確認します';

  @override
  void initState() {
    super.initState();
    if (widget.active) _refresh();
  }

  @override
  void didUpdateWidget(covariant SavedDownloadsPane oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.active && !oldWidget.active) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = '保存済みデータを確認中';
    });

    try {
      final result = await SavedDownloadRepository(
        widget.store,
        widget.adapter,
      ).scan();

      final works = <String, ComicWork>{};
      final tabs = <String, SourceTab>{};
      final warnings = List<String>.of(result.issues);

      String keyFor(String language, String workId) =>
          '${widget.adapter.id}:$language:$workId';

      final languages = result.chapters
          .map((item) => item.chapter.language)
          .toSet();

      // 作品名を端末内キャッシュ・初期データから復元。
      // fetchWorksなどのネットワーク取得は呼ばない。
      for (final language in languages) {
        final query = BrowseQuery(language: language);

        for (final work in widget.adapter.fallbackWorks(query)) {
          works[keyFor(language, work.id)] = work;
        }

        final cached = await widget.store.readCache(
          '${widget.adapter.id}:works:${query.toJson()}',
        );

        if (cached is List) {
          for (final entry in cached) {
            try {
              final work = ComicWork.fromJson(
                Map<String, dynamic>.from(entry as Map),
              );
              works[keyFor(language, work.id)] = work;
            } catch (_) {
              // 読める項目を優先。
            }
          }
        }
      }

      final library = UserLibraryStore.forRoot(widget.store.root);

      try {
        await library.load();

        for (final item in [
          ...library.history.reversed,
          ...library.favorites.reversed,
        ]) {
          if (item.sourceId != widget.adapter.id) continue;

          final key = keyFor(item.tab.query.language, item.work.id);
          works[key] = item.work;
          tabs[key] = item.tab;
        }
      } catch (error) {
        warnings.add('作品名の補助情報を読み込めませんでした：$error');
      }

      final grouped = <String, List<SavedChapter>>{};

      for (final item in result.chapters) {
        grouped.putIfAbsent(savedWorkKey(item.chapter), () => []).add(item);
      }

      final groups = <_SavedGroup>[];

      for (final entry in grouped.entries) {
        final chapter = entry.value.first.chapter;
        final metadataKey = keyFor(chapter.language, chapter.workId);

        SourceTab? tab = tabs[metadataKey];

        for (final candidate in widget.adapter.defaultTabs) {
          if (tab == null && candidate.query.language == chapter.language) {
            tab = candidate;
          }
        }

        groups.add(
          _SavedGroup(
            key: entry.key,
            work: works[metadataKey],
            tab:
                tab ??
                SourceTab(
                  chapter.language,
                  chapter.language,
                  BrowseQuery(language: chapter.language),
                ),
            items: entry.value,
          ),
        );
      }

      final custom = await loadRuleLibrarySaved(widget.store);
      warnings.addAll(custom.issues);

      for (final group in custom.groups) {
        groups.add(
          _SavedGroup(
            key: group.key,
            work: group.record.work,
            tab: group.record.tab,
            items: group.items,
            adapter: RuleLibraryOfflineAdapter(group.record.sourceId),
          ),
        );
      }

      groups.sort((a, b) {
        final title = a.title.compareTo(b.title);
        return title != 0 ? title : a.tab.title.compareTo(b.tab.title);
      });

      if (!mounted) return;

      setState(() {
        _groups = groups;
        _issues = warnings;
        _status =
            '${groups.length}作品・${groups.fold<int>(0, (sum, group) => sum + group.items.length)}話'
            '・${savedSizeLabel(groups.fold<int>(0, (sum, group) => sum + group.bytes))}\n'
            '現在のサイトの保存完了データ'
            '${warnings.isEmpty ? '' : '・確認事項${warnings.length}件'}';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '保存済み一覧を読み込めませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(_SavedGroup group) async {
    if (_busy) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _SavedChaptersPage(
          adapter: group.adapter ?? widget.adapter,
          store: widget.store,
          group: group,
        ),
      ),
    );

    if (mounted) await _refresh();
  }

  void _showIssues() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('一覧作成時の確認事項'),
        content: SingleChildScrollView(
          child: SelectableText(_issues.join('\n\n')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final statusHeight = (scaler.scale(14) * 1.4 * 2).ceilToDouble() + 12;
    final measuredRow =
        scaler.scale(16) * 1.3 * 2 + scaler.scale(13) * 1.4 * 2 + 28;
    final rowHeight = measuredRow < 124 ? 124.0 : measuredRow;

    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: SizedBox(
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
              ),
            ),
            IconButton(
              tooltip: '保存済み動画',
              onPressed: _busy
                  ? null
                  : () async {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => SavedVideosPage(store: widget.store),
                        ),
                      );
                      if (mounted) await _refresh();
                    },
              icon: const Icon(Icons.video_library_outlined),
            ),
            IconButton(
              tooltip: '未完了ダウンロード',
              onPressed: _busy || widget.store.hasActiveDownloads
                  ? null
                  : () async {
                      await Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => IncompleteDownloadsPage(
                            adapter: widget.adapter,
                            store: widget.store,
                          ),
                        ),
                      );
                      if (mounted) await _refresh();
                    },
              icon: const Icon(Icons.downloading_outlined),
            ),
            IconButton(
              tooltip: '確認事項',
              onPressed: _busy || _issues.isEmpty ? null : _showIssues,
              icon: const Icon(Icons.info_outline),
            ),
            IconButton(
              tooltip: '保存済み一覧を更新',
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        SizedBox(
          height: 3,
          child: _busy
              ? const LinearProgressIndicator(minHeight: 3)
              : const SizedBox.expand(),
        ),
        Expanded(
          child: _groups.isEmpty
              ? const Center(child: Text('保存済みの話はありません'))
              : ListView.builder(
                  key: PageStorageKey('saved:${widget.adapter.id}'),
                  itemExtent: rowHeight,
                  itemCount: _groups.length,
                  itemBuilder: (context, index) {
                    final group = _groups[index];

                    return Material(
                      key: ValueKey(group.key),
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _busy ? null : () => _open(group),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              _localPreview(group.items.first, 66, 96),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      group.title,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        height: 1.3,
                                      ),
                                    ),
                                    Text(
                                      '${group.tab.title}・${group.items.length}話',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 13,
                                        height: 1.4,
                                        color: Colors.white60,
                                      ),
                                    ),
                                    Text(
                                      savedSizeLabel(group.bytes),
                                      style: const TextStyle(
                                        fontSize: 13,
                                        height: 1.4,
                                        color: Colors.tealAccent,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
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

class _SavedChaptersPage extends StatefulWidget {
  const _SavedChaptersPage({
    required this.adapter,
    required this.store,
    required this.group,
  });

  final SourceAdapter adapter;
  final DownloadStore store;
  final _SavedGroup group;

  @override
  State<_SavedChaptersPage> createState() => _SavedChaptersPageState();
}

class _SavedChaptersPageState extends State<_SavedChaptersPage> {
  late List<SavedChapter> _items;
  final Set<String> _selected = {};
  bool _busy = false;
  String _status = 'チェックした話を選択削除できます';

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.group.items);
  }

  Future<void> _reload() async {
    final scan = await SavedDownloadRepository(
      widget.store,
      widget.adapter,
    ).scan();

    if (!mounted) return;

    setState(() {
      _items = scan.chapters
          .where((item) => savedWorkKey(item.chapter) == widget.group.key)
          .toList();

      final remaining = _items.map((item) => item.chapter.storageId).toSet();

      _selected.removeWhere((id) => !remaining.contains(id));
    });
  }

  Future<void> _open(SavedChapter item) async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final chapters = _items.map((entry) => entry.chapter).toList();
      final index = chapters.indexWhere(
        (chapter) => chapter.storageId == item.chapter.storageId,
      );

      final work = widget.group.work;

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChapterReaderPage(
            adapter: widget.adapter,
            store: widget.store,
            chapters: chapters,
            initialIndex: index,
            offlineOnly: true,
            onChapterOpened: work == null
                ? null
                : (chapter) =>
                      UserLibraryStore.forRoot(widget.store.root).remember(
                        widget.adapter.id,
                        widget.group.tab,
                        work,
                        chapter,
                      ),
          ),
        ),
      );

      if (mounted) await _reload();
    } catch (error) {
      if (mounted) {
        setState(() => _status = '開けませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(List<SavedChapter> targets) async {
    if (_busy || targets.isEmpty) return;

    final bytes = targets.fold<int>(0, (sum, item) => sum + item.bytes);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存画像を削除'),
        content: SingleChildScrollView(
          child: Text(
            '${widget.group.title}・${widget.group.tab.title}\n'
            '${targets.length}話・${savedSizeLabel(bytes)}\n\n'
            '${targets.take(6).map((item) => item.chapter.title).join('\n')}'
            '${targets.length > 6 ? '\nほか${targets.length - 6}話' : ''}'
            '\n\nお気に入り・履歴・閲覧位置・読了状態は残します。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('削除する'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    var deleted = 0;
    final errors = <String>[];

    try {
      final repository = SavedDownloadRepository(widget.store, widget.adapter);

      for (final target in targets) {
        try {
          await repository.deleteChapter(target);
          deleted++;
        } catch (error) {
          errors.add('${target.chapter.title}：$error');
        }
      }

      await _reload();

      if (mounted) {
        setState(() {
          _status =
              '$deleted話を削除・失敗${errors.length}話'
              '${errors.isEmpty ? '' : '\n${errors.join('\n')}'}';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = '削除後の一覧更新に失敗しました：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scaler = MediaQuery.textScalerOf(context);
    final total = _items.fold<int>(0, (sum, item) => sum + item.bytes);
    final selected = _items
        .where((item) => _selected.contains(item.chapter.storageId))
        .toList();

    final statusHeight = (scaler.scale(13) * 1.4 * 2).ceilToDouble() + 12;
    final measuredRow =
        scaler.scale(15) * 1.3 * 2 + scaler.scale(12) * 1.4 * 2 + 32;
    final rowHeight = measuredRow < 124 ? 124.0 : measuredRow;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: Text('${widget.group.title}・保存済み'),
          actions: [
            IconButton(
              tooltip: 'この作品の保存済み全話を削除',
              onPressed: _busy || _items.isEmpty
                  ? null
                  : () => _delete(List.of(_items)),
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_items.length}話・${savedSizeLabel(total)}'
                      '・選択${selected.length}話',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _busy || selected.isEmpty
                        ? null
                        : () => _delete(selected),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('選択削除'),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                height: statusHeight,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: _status,
                    child: Text(
                      _status,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: Colors.white60,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              height: 3,
              child: _busy
                  ? const LinearProgressIndicator(minHeight: 3)
                  : const SizedBox.expand(),
            ),
            Expanded(
              child: _items.isEmpty
                  ? const Center(child: Text('この作品の保存画像はありません'))
                  : ListView.builder(
                      itemExtent: rowHeight,
                      itemCount: _items.length,
                      itemBuilder: (context, index) {
                        final item = _items[index];
                        final chapter = item.chapter;

                        return Material(
                          key: ValueKey(chapter.storageId),
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _busy ? null : () => _open(item),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 44,
                                    child: Checkbox(
                                      value: _selected.contains(
                                        chapter.storageId,
                                      ),
                                      onChanged: _busy
                                          ? null
                                          : (value) {
                                              setState(() {
                                                if (value == true) {
                                                  _selected.add(
                                                    chapter.storageId,
                                                  );
                                                } else {
                                                  _selected.remove(
                                                    chapter.storageId,
                                                  );
                                                }
                                              });
                                            },
                                    ),
                                  ),
                                  _localPreview(item, 52, 82),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          chapter.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            height: 1.3,
                                          ),
                                        ),
                                        Text(
                                          chapterDateLabel(chapter),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            height: 1.4,
                                            color: Colors.white54,
                                          ),
                                        ),
                                        Row(
                                          children: [
                                            Expanded(
                                              child: ChapterReadStatus(
                                                store:
                                                    ChapterReadStateStore.forRoot(
                                                      widget.store.root,
                                                    ),
                                                chapter: chapter,
                                              ),
                                            ),
                                            Text(
                                              savedSizeLabel(item.bytes),
                                              style: const TextStyle(
                                                fontSize: 12,
                                                height: 1.4,
                                                color: Colors.tealAccent,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
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
