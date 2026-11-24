import 'package:flutter/material.dart';

import 'chapter_reader_page.dart';
import 'cover_widgets.dart';
import 'services/download_store.dart';
import 'services/favorite_update_store.dart';
import 'services/user_library_store.dart';
import 'sources/source_adapter.dart';

class _NewChapter {
  const _NewChapter(this.favorite, this.snapshot, this.chapter);

  final LibraryItem favorite;
  final FavoriteUpdateSnapshot snapshot;
  final ComicChapter chapter;
}

class FavoriteUpdatesPage extends StatefulWidget {
  const FavoriteUpdatesPage({
    super.key,
    required this.adapter,
    required this.store,
    required this.library,
  });

  final SourceAdapter adapter;
  final DownloadStore store;
  final UserLibraryStore library;

  @override
  State<FavoriteUpdatesPage> createState() => _FavoriteUpdatesPageState();
}

class _FavoriteUpdatesPageState extends State<FavoriteUpdatesPage> {
  late final FavoriteUpdateStore _updates;

  List<_NewChapter> _rows = [];
  final Set<String> _saved = {};
  final List<String> _errors = [];

  bool _busy = true;
  bool _checking = false;
  bool _stop = false;
  bool _ready = false;

  String _status = '新着記録を読み込み中';

  @override
  void initState() {
    super.initState();
    _updates = FavoriteUpdateStore.forRoot(widget.store.root);
    _initialize();
  }

  List<LibraryItem> get _favorites => widget.library.favorites
      .where((item) => item.sourceId == widget.adapter.id)
      .toList();

  Future<void> _initialize() async {
    try {
      await widget.library.load();
      await _reload();

      if (mounted) {
        setState(() {
          _ready = true;
          _status = '「確認」でお気に入りの新着を調べます';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = '記録を読み込めませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reload() async {
    final rows = <_NewChapter>[];
    final saved = <String>{};

    for (final favorite in _favorites) {
      final snapshot = await _updates.read(favorite.workKey);
      if (snapshot == null) continue;

      for (final chapter in snapshot.chapters) {
        if (!snapshot.newIds.contains(chapter.id)) continue;

        rows.add(_NewChapter(favorite, snapshot, chapter));

        try {
          if ((await widget.store.load(chapter)).isNotEmpty) {
            saved.add(chapter.storageId);
          }
        } catch (_) {
          // 不完全な保存は、再保存可能な状態として表示。
        }
      }
    }

    rows.sort((a, b) {
      final date = b.snapshot.checkedAt.compareTo(a.snapshot.checkedAt);
      return date != 0 ? date : b.chapter.id.compareTo(a.chapter.id);
    });

    if (!mounted) return;

    setState(() {
      _rows = rows;
      _saved
        ..clear()
        ..addAll(saved);
    });
  }

  Future<void> _check() async {
    if (_busy || !_ready) return;

    final favorites = _favorites;

    if (favorites.isEmpty) {
      setState(() => _status = '先に作品をお気に入りへ登録してください');
      return;
    }

    setState(() {
      _busy = true;
      _checking = true;
      _stop = false;
      _errors.clear();
    });

    var baselines = 0;
    var additions = 0;

    try {
      for (var index = 0; index < favorites.length; index++) {
        if (_stop) break;

        final favorite = favorites[index];

        if (!mounted) return;

        setState(() {
          _status =
              '${index + 1} / ${favorites.length} 作品を確認中\n'
              '${favorite.work.title}・${favorite.tab.title}';
        });

        try {
          final chapters = await widget.adapter.fetchChapters(
            favorite.work,
            favorite.tab.query,
          );

          if (chapters.any(
            (chapter) =>
                chapter.sourceId != favorite.sourceId ||
                chapter.language != favorite.tab.query.language ||
                chapter.workId != favorite.work.id,
          )) {
            throw const FormatException('別作品・別言語の話が含まれています');
          }

          final added = await _updates.apply(favorite.workKey, chapters);

          if (added == null) {
            baselines++;
          } else {
            additions += added;
          }
        } catch (error) {
          _errors.add('${favorite.work.title}・${favorite.tab.title}\n$error');
        }

        if (!_stop && index < favorites.length - 1) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }

      await _reload();

      if (!mounted) return;

      setState(() {
        _status =
            '${_stop ? '確認を停止' : '確認完了'}：新たに$additions話を検出\n'
            '初回登録$baselines作品・失敗${_errors.length}作品';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '確認処理を完了できませんでした：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _checking = false;
        });
      }
    }
  }

  Future<void> _open(_NewChapter row) async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final chapters = row.snapshot.chapters;
      final index = chapters.indexWhere(
        (chapter) => chapter.id == row.chapter.id,
      );

      if (index < 0) {
        throw StateError('チャプターが見つかりません');
      }

      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChapterReaderPage(
            adapter: widget.adapter,
            store: widget.store,
            chapters: List.unmodifiable(chapters),
            initialIndex: index,
            onChapterOpened: (chapter) => widget.library.remember(
              row.favorite.sourceId,
              row.favorite.tab,
              row.favorite.work,
              chapter,
            ),
          ),
        ),
      );

      await _reload();

      if (mounted) {
        setState(() => _status = '未確認の新着：${_rows.length}話');
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = '開けませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(_NewChapter row) async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _status = '${row.chapter.title}を保存中';
    });

    try {
      var alreadySaved = false;

      try {
        alreadySaved = (await widget.store.load(row.chapter)).isNotEmpty;
      } catch (_) {
        // 保存が不完全なら取得し直す。
      }

      if (!alreadySaved) {
        final content = await widget.adapter.fetchContent(row.chapter);

        await widget.store.download(row.chapter, content, (done, total) {
          if (mounted) {
            setState(() {
              _status =
                  '${row.chapter.title}\n'
                  '$done / $total ページ保存中';
            });
          }
        });
      }

      if (mounted) {
        setState(() {
          _saved.add(row.chapter.storageId);
          _status = '保存済み：${row.chapter.title}';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = '保存できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showErrors() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('確認できなかった作品'),
        content: SingleChildScrollView(
          child: SelectableText(_errors.join('\n\n')),
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
    final statusHeight = (scaler.scale(14) * 1.4 * 2).ceilToDouble() + 8;

    final measuredRowHeight =
        scaler.scale(15) * 1.3 * 2 +
        scaler.scale(13) * 1.3 * 2 +
        scaler.scale(12) * 1.3 +
        28;

    final rowHeight = measuredRowHeight < 120 ? 120.0 : measuredRowHeight;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('お気に入り新着'),
          actions: [
            IconButton(
              tooltip: '失敗した作品の詳細',
              onPressed: _busy || _errors.isEmpty ? null : _showErrors,
              icon: const Icon(Icons.info_outline),
            ),
            TextButton.icon(
              onPressed: _checking
                  ? (_stop ? null : () => setState(() => _stop = true))
                  : (_busy || !_ready ? null : _check),
              icon: Icon(_checking ? Icons.stop : Icons.refresh),
              label: Text(_checking ? (_stop ? '停止待ち' : '停止') : '確認'),
            ),
          ],
        ),
        body: Column(
          children: [
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
                      style: const TextStyle(fontSize: 14, height: 1.4),
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
              child: _rows.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          '未確認の新着はありません\n\n'
                          '初回の確認は比較基準の登録です。\n'
                          '次回以降、追加された話を表示します。',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemExtent: rowHeight,
                      itemCount: _rows.length,
                      itemBuilder: (context, index) {
                        final row = _rows[index];
                        final saved = _saved.contains(row.chapter.storageId);

                        return Material(
                          key: ValueKey(
                            '${row.favorite.workKey}:${row.chapter.id}',
                          ),
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: _busy ? null : () => _open(row),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 60,
                                    height: 90,
                                    child: WorkCover(
                                      url: row.favorite.work.thumbnail,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          row.favorite.work.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 15,
                                            height: 1.3,
                                          ),
                                        ),
                                        Text(
                                          row.chapter.title,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            height: 1.3,
                                            color: Colors.lightBlueAccent,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          row.favorite.tab.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            height: 1.3,
                                            color: Colors.white54,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: IconButton(
                                      tooltip: saved ? '保存済み' : 'この話を保存',
                                      onPressed: _busy || saved
                                          ? null
                                          : () => _download(row),
                                      icon: Icon(
                                        saved
                                            ? Icons.offline_pin
                                            : Icons.download,
                                        color: saved ? Colors.tealAccent : null,
                                      ),
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
