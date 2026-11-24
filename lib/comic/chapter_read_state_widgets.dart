import 'package:flutter/material.dart';

import 'reading_progress.dart';
import 'services/chapter_read_state_store.dart';
import 'sources/source_adapter.dart';

class ChapterReadStatus extends StatefulWidget {
  const ChapterReadStatus({
    super.key,
    required this.store,
    required this.chapter,
    this.button = false,
  });

  final ChapterReadStateStore store;
  final ComicChapter chapter;
  final bool button;

  @override
  State<ChapterReadStatus> createState() => _ChapterReadStatusState();
}

class _ChapterReadStatusState extends State<ChapterReadStatus> {
  late Future<void> _ready;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ready = _prepare();
  }

  @override
  void didUpdateWidget(covariant ChapterReadStatus oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.store != widget.store ||
        chapterReadStateKey(oldWidget.chapter) !=
            chapterReadStateKey(widget.chapter)) {
      _error = null;
      _ready = _prepare();
    }
  }

  Future<void> _prepare() async {
    final store = widget.store;
    final chapter = widget.chapter;

    await store.load();

    if (store.hasRecord(chapter)) return;

    final progress = await ReadingProgressStore.instance.load(
      ReadingKey(
        sourceId: chapter.progressSourceId,
        chapterId: chapter.progressChapterId,
      ),
    );

    if (progress != null) {
      await store.importStarted(chapter);
    }
  }

  Future<void> _complete() async {
    if (_saving) return;

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      await widget.store.setChapterState(
        widget.chapter,
        ChapterReadState.completed,
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = '読了を保存できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, snapshot) {
        return AnimatedBuilder(
          animation: widget.store,
          builder: (context, child) {
            final state = widget.store.stateOf(widget.chapter);
            final pending = snapshot.connectionState != ConnectionState.done;
            final failed = snapshot.hasError;

            final label = failed
                ? '読書状態を読み込めません'
                : pending
                ? '読書状態を確認中'
                : switch (state) {
                    ChapterReadState.unread => '未読',
                    ChapterReadState.reading => '読書中',
                    ChapterReadState.completed => '読了',
                  };

            final color = failed
                ? Colors.redAccent
                : switch (state) {
                    ChapterReadState.unread => Colors.white54,
                    ChapterReadState.reading => Colors.lightBlueAccent,
                    ChapterReadState.completed => Colors.tealAccent,
                  };

            if (widget.button) {
              return SizedBox(
                width: 48,
                height: 48,
                child: IconButton(
                  tooltip:
                      _error ??
                      (failed
                          ? '読書状態を読み込めませんでした'
                          : state == ChapterReadState.completed
                          ? '読了済み'
                          : 'この話を読了にする'),
                  onPressed:
                      pending ||
                          failed ||
                          _saving ||
                          state == ChapterReadState.completed
                      ? null
                      : _complete,
                  icon: Icon(
                    _error != null || failed
                        ? Icons.error_outline
                        : state == ChapterReadState.completed
                        ? Icons.check_circle
                        : Icons.check_circle_outline,
                    color: _error != null
                        ? Colors.redAccent
                        : state == ChapterReadState.completed
                        ? Colors.tealAccent
                        : null,
                  ),
                ),
              );
            }

            return Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, height: 1.4, color: color),
            );
          },
        );
      },
    );
  }
}
