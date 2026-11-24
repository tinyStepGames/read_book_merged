import 'cover_widgets.dart';
import 'reading_progress.dart';
import 'package:flutter/material.dart';

import 'services/user_library_store.dart';
import 'services/rule_library.dart';
import 'sources/source_adapter.dart';

class FavoriteWorkButton extends StatefulWidget {
  const FavoriteWorkButton({
    super.key,
    required this.library,
    required this.sourceId,
    required this.tab,
    required this.work,
  });

  final UserLibraryStore library;
  final String sourceId;
  final SourceTab tab;
  final ComicWork work;

  @override
  State<FavoriteWorkButton> createState() => _FavoriteWorkButtonState();
}

class _FavoriteWorkButtonState extends State<FavoriteWorkButton> {
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await widget.library.load();
    } catch (error) {
      _error = 'お気に入りを読み込めませんでした：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);

    try {
      await widget.library.toggleFavorite(
        widget.sourceId,
        widget.tab,
        widget.work,
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('お気に入りを保存できませんでした：$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.library,
      builder: (context, child) {
        final selected = widget.library.isFavorite(
          widget.sourceId,
          widget.tab,
          widget.work,
        );

        return SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
            tooltip: _error ?? (selected ? 'お気に入りを解除' : 'お気に入りに登録'),
            onPressed: _busy || _error != null ? null : _toggle,
            icon: Icon(
              _error != null
                  ? Icons.error_outline
                  : selected
                  ? Icons.star
                  : Icons.star_border,
              color: selected ? Colors.amber : null,
            ),
          ),
        );
      },
    );
  }
}

class LibraryShelf extends StatefulWidget {
  const LibraryShelf({
    super.key,
    required this.library,
    required this.sourceId,
    required this.history,
    required this.onOpen,
    this.sourceName,
    this.includeCustomSites = false,
  });

  final UserLibraryStore library;
  final String sourceId;
  final String? sourceName;
  final bool includeCustomSites;
  final bool history;
  final Future<void> Function(LibraryItem item) onOpen;

  @override
  State<LibraryShelf> createState() => _LibraryShelfState();
}

class _LibraryShelfState extends State<LibraryShelf> {
  late final Future<void> _loading;

  final Map<String, Future<ReadingProgress?>> _progress = {};

  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loading = widget.library.load();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await action();
    } catch (error) {
      if (mounted) {
        setState(() => _error = '処理できませんでした：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          // 読書画面から戻ったら、最新のページ位置を読み直す。
          _progress.clear();
        });
      }
    }
  }

  Future<ReadingProgress?> _position(LibraryItem item) {
    final chapter = item.chapter!;

    return _progress.putIfAbsent(
      item.historyKey,
      () => ReadingProgressStore.instance.load(
        ReadingKey(
          sourceId: chapter.progressSourceId,
          chapterId: chapter.progressChapterId,
        ),
      ),
    );
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
                child: const Text('削除'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _clear() async {
    final confirmed = await _confirm(
      '閲覧履歴を消去',
      widget.includeCustomSites
          ? '表示対象のサイトの履歴を消去しますか？\n'
                '保存画像・お気に入り・閲覧位置は残ります。'
          : 'このサイトの履歴を消去しますか？\n'
                '保存画像・お気に入り・閲覧位置は残ります。',
    );

    if (confirmed && mounted) {
      await _run(() async {
        final sources = <String>{
          widget.sourceId,
          if (widget.includeCustomSites)
            for (final item in widget.library.history)
              if (isRuleLibrarySource(item.sourceId)) item.sourceId,
        };

        for (final sourceId in sources) {
          await widget.library.clearHistory(sourceId);
        }
      });
    }
  }

  Future<void> _remove(LibraryItem item) async {
    final confirmed = await _confirm(
      'この履歴を削除',
      '${item.work.title}\n${item.chapter!.title}\n\n'
          'この履歴だけを削除しますか？',
    );

    if (confirmed && mounted) {
      await _run(() => widget.library.removeHistory(item));
    }
  }

  String _date(DateTime value) => value.toLocal().toString().substring(0, 16);

  Widget _historyRow(LibraryItem item) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _busy ? null : () => _run(() => widget.onOpen(item)),
        onLongPress: _busy ? null : () => _remove(item),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(width: 66, child: WorkCover(url: item.work.thumbnail)),
              const SizedBox(width: 10),
              Expanded(
                child: FutureBuilder<ReadingProgress?>(
                  future: _position(item),
                  builder: (context, snapshot) {
                    final saved = snapshot.data;
                    final page = saved == null
                        ? ''
                        : '（P${saved.pageIndex + 1}）';

                    final opened = item.updatedAt;
                    final updated = saved?.updatedAt;
                    final date = updated != null && updated.isAfter(opened)
                        ? updated
                        : opened;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.work.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.3,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${item.chapter!.title}$page',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            height: 1.3,
                            color: Colors.white60,
                          ),
                        ),
                        const Spacer(),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${isRuleLibrarySource(item.sourceId) ? "作成サイト" : widget.sourceName ?? item.sourceId}'
                                '・${item.tab.title}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  height: 1.3,
                                  color: Colors.white54,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _date(date),
                              style: const TextStyle(
                                fontSize: 11,
                                height: 1.3,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _loading,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText('記録を読み込めませんでした。\n${snapshot.error}'),
            ),
          );
        }

        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }

        return AnimatedBuilder(
          animation: widget.library,
          builder: (context, child) {
            final items =
                (widget.history
                        ? widget.library.history
                        : widget.library.favorites)
                    .where(
                      (item) =>
                          item.sourceId == widget.sourceId ||
                          (widget.includeCustomSites &&
                              isRuleLibrarySource(item.sourceId)),
                    )
                    .toList();

            final scaler = MediaQuery.textScalerOf(context);

            // 読み込み前後で履歴行の高さを変えない。
            final measuredHeight =
                scaler.scale(15) * 1.3 * 2 +
                scaler.scale(13) * 1.3 +
                scaler.scale(11) * 1.3 +
                36;

            final rowHeight = measuredHeight < 120 ? 120.0 : measuredHeight;

            return Column(
              children: [
                SizedBox(
                  height: 48,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Text('${items.length}件'),
                      const Spacer(),
                      if (widget.history) ...[
                        const Text(
                          '長押しで個別削除',
                          style: TextStyle(fontSize: 11, color: Colors.white54),
                        ),
                        IconButton(
                          tooltip: '履歴を消去',
                          onPressed: _busy || items.isEmpty ? null : _clear,
                          icon: const Icon(Icons.delete_sweep_outlined),
                        ),
                      ],
                    ],
                  ),
                ),

                // 処理中だけ一覧が動かないよう、領域を常に確保。
                SizedBox(
                  height: 3,
                  child: _busy
                      ? const LinearProgressIndicator(minHeight: 3)
                      : const SizedBox.expand(),
                ),

                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ),

                Expanded(
                  child: items.isEmpty
                      ? Center(
                          child: Text(
                            widget.history
                                ? '閲覧履歴はまだありません'
                                : 'お気に入りはまだありません\n'
                                      'チャプター一覧の☆で登録できます',
                            textAlign: TextAlign.center,
                          ),
                        )
                      : widget.history
                      ? ListView.builder(
                          key: PageStorageKey('history:${widget.sourceId}'),
                          itemExtent: rowHeight,
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final item = items[index];

                            return Column(
                              key: ValueKey(item.historyKey),
                              children: [
                                Expanded(child: _historyRow(item)),
                                const Divider(
                                  height: 1,
                                  thickness: 0.5,
                                  indent: 10,
                                  endIndent: 10,
                                  color: Colors.white12,
                                ),
                              ],
                            );
                          },
                        )
                      : CoverGrid<LibraryItem>(
                          items: items,
                          workOf: (item) => item.work,
                          subtitleOf: (item) => item.tab.title,
                          onOpen: (item) {
                            if (!_busy) {
                              _run(() => widget.onOpen(item));
                            }
                          },
                          badgeBuilder: (item) => FavoriteWorkButton(
                            library: widget.library,
                            sourceId: item.sourceId,
                            tab: item.tab,
                            work: item.work,
                          ),
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
