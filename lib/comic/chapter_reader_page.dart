import 'chapter_read_state_widgets.dart';
import 'services/chapter_read_state_store.dart';
import 'dart:io';

import 'package:flutter/material.dart';

import 'reader_page.dart';
import 'reading_progress.dart';
import 'services/download_store.dart';
import 'sources/source_adapter.dart';

/// サイト固有のHTMLやURL構造を知らない、共通の連続閲覧画面。
/// chaptersの順序を、そのまま前後移動の順序として使う。
class ChapterReaderPage extends StatefulWidget {
  const ChapterReaderPage({
    super.key,
    required this.adapter,
    required this.store,
    required this.chapters,
    required this.initialIndex,
    this.onChapterOpened,
    this.offlineOnly = false,
  }) : assert(chapters.length > 0),
       assert(initialIndex >= 0 && initialIndex < chapters.length);

  final SourceAdapter adapter;
  final DownloadStore store;
  final List<ComicChapter> chapters;
  final int initialIndex;
  final bool offlineOnly;
  final Future<void> Function(ComicChapter chapter)? onChapterOpened;

  @override
  State<ChapterReaderPage> createState() => _ChapterReaderPageState();
}

class _ChapterReaderPageState extends State<ChapterReaderPage> {
  late int _index;

  List<File> _files = [];
  List<Uri> _images = [];

  bool _loading = false;
  bool _opened = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _load(_index);
  }

  Future<void> _load(int target) async {
    if (_loading || target < 0 || target >= widget.chapters.length) {
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final chapter = widget.chapters[target];

    try {
      List<File> files = [];

      try {
        files = await widget.store.load(chapter);
      } catch (_) {
        // 保存が不完全なら、オンラインでの取得を試す。
      }

      List<Uri> images = [];

      if (files.isEmpty) {
        if (widget.offlineOnly) {
          throw StateError('保存ファイルが不足しています。保存済み一覧を更新してください。');
        }

        final content = await widget.adapter.fetchContent(chapter);
        images = content.images;

        try {
          await widget.store.rememberCredits(chapter, content.credits);
        } catch (_) {
          // クレジットの書き込み失敗だけで閲覧を止めない。
        }
      }

      if (files.isEmpty && images.isEmpty) {
        throw StateError('本文画像がありません');
      }

      if (!mounted) return;

      setState(() {
        _index = target;
        _files = files;
        _images = images;
        _opened = true;
      });

      try {
        await ChapterReadStateStore.forRoot(
          widget.store.root,
        ).markOpened(chapter);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('読書状態を保存できませんでした：$error')));
        }
      }

      try {
        await widget.onChapterOpened?.call(chapter);
      } catch (error) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('閲覧履歴を保存できませんでした：$error')));
        }
      }
    } catch (error) {
      if (!mounted) return;

      final hint = widget.offlineOnly
          ? '保存済み一覧からはオンライン取得を行いません。'
          : '未保存の話にはネット接続が必要です。';

      final message =
          '「${chapter.title}」を開けませんでした。\n'
          '$hint\n$error';

      if (_opened) {
        // 現在の話は消さず、そのまま残す。
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(message)));
      } else {
        setState(() => _error = message);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final chapter = widget.chapters[_index];

    if (!_opened) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(chapter.title)),
        body: Center(
          child: _loading
              ? const CircularProgressIndicator()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _error ?? 'チャプターを開けませんでした',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => _load(_index),
                        icon: const Icon(Icons.refresh),
                        label: const Text('再試行'),
                      ),
                    ],
                  ),
                ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        AbsorbPointer(
          absorbing: _loading,
          child: ReaderPage(
            // 話が変わったら別のリーダー状態に切り替え、
            // それぞれの閲覧位置を保存・復元する。
            key: ValueKey('$_index:${chapter.url}'),
            files: _files,
            imageUrls: _images,
            title: chapter.title,
            chapterStateAction: ChapterReadStatus(
              store: ChapterReadStateStore.forRoot(widget.store.root),
              chapter: chapter,
              button: true,
            ),
            progressKey: ReadingKey(
              sourceId: chapter.progressSourceId,
              chapterId: chapter.progressChapterId,
            ),
            onPreviousChapter: _index > 0 ? () => _load(_index - 1) : null,
            onNextChapter: _index < widget.chapters.length - 1
                ? () => _load(_index + 1)
                : null,
          ),
        ),
        if (_loading)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x99000000),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }
}
