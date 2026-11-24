import 'dart:async';
import 'package:flutter/material.dart';

import 'reader_page.dart';
import 'reading_progress.dart';
import 'services/rule_downloads.dart';
import 'services/saved_download_repository.dart';
import 'services/site_rule_store.dart';
import 'services/rule_library.dart';
import 'services/rule_browse_client.dart';

class RuleSavedDownloadsPage extends StatefulWidget {
  const RuleSavedDownloadsPage({super.key, required this.site});

  final SavedSiteRule site;

  @override
  State<RuleSavedDownloadsPage> createState() => _RuleSavedDownloadsPageState();
}

class _RuleSavedDownloadsPageState extends State<RuleSavedDownloadsPage> {
  RuleDownloads? _downloads;
  SavedDownloadScan? _scan;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final downloads = await RuleDownloads.open();
      final scan = await downloads.scan(widget.site.id);

      if (!mounted) return;
      setState(() {
        _downloads = downloads;
        _scan = scan;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(int index) async {
    final scan = _scan;
    if (scan == null || _busy) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _RuleLocalReaderPage(
          site: widget.site,
          chapters: scan.chapters,
          initialIndex: index,
        ),
      ),
    );
  }

  Future<void> _delete(SavedChapter item) async {
    final downloads = _downloads;
    if (downloads == null || _busy) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('保存画像を削除'),
        content: Text(
          '「${item.chapter.title}」の保存画像を削除しますか？\n'
          '閲覧位置やサイトルールは削除しません。',
        ),
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
    );

    if (!mounted || confirmed != true) return;

    try {
      await downloads.delete(item);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final scan = _scan;
    final downloads = _downloads;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text('${widget.site.name}・保存済み'),
        actions: [
          IconButton(
            tooltip: '保存状態を再確認',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(
            height: 3,
            child: _busy ? const LinearProgressIndicator() : null,
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                _error!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          if (scan != null && scan.issues.isNotEmpty)
            ExpansionTile(
              title: Text('確認が必要な保存データ：${scan.issues.length}件'),
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(scan.issues.join('\n')),
                ),
              ],
            ),
          Expanded(
            child: scan == null
                ? const SizedBox.expand()
                : scan.chapters.isEmpty
                ? const Center(
                    child: Text(
                      '保存が完了した話はありません。\n'
                      'オンライン時にチャプター一覧の↓から保存できます。',
                      textAlign: TextAlign.center,
                    ),
                  )
                : ListView.builder(
                    itemCount: scan.chapters.length,
                    itemBuilder: (context, index) {
                      final item = scan.chapters[index];

                      return ListTile(
                        leading: const Icon(Icons.offline_pin_outlined),
                        title: Text(item.chapter.title),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (downloads != null)
                              FutureBuilder<String>(
                                future: downloads.workTitle(item.chapter),
                                builder: (context, snapshot) => Text(
                                  snapshot.data ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            Text(
                              '${item.files.length}ページ'
                              ' ・ ${savedSizeLabel(item.bytes)}',
                            ),
                          ],
                        ),
                        onTap: () => _open(index),
                        trailing: IconButton(
                          tooltip: '保存画像を削除',
                          onPressed: () => _delete(item),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// HTML取得やImage.networkを使用しない保存済み専用画面。
class _RuleLocalReaderPage extends StatefulWidget {
  const _RuleLocalReaderPage({
    required this.chapters,
    required this.initialIndex,
    required this.site,
  });

  final List<SavedChapter> chapters;
  final int initialIndex;
  final SavedSiteRule site;

  @override
  State<_RuleLocalReaderPage> createState() => _RuleLocalReaderPageState();
}

class _RuleLocalReaderPageState extends State<_RuleLocalReaderPage> {
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
  }

  Future<void> _remember(SavedChapter item) async {
    try {
      final downloads = await RuleDownloads.open();
      final title = await downloads.workTitle(item.chapter);

      await rememberRuleLibrary(
        store: downloads.store,
        record: ruleLibraryWork(
          site: widget.site,
          workUrl: item.chapter.workId,
          title: title,
        ),
        chapter: RuleBrowseItem(
          title: item.chapter.title,
          url: item.chapter.url,
          thumbnail: null,
          date: item.chapter.publishedDateText ?? '',
          latestChapter: '',
          issues: const [],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('履歴を保存できませんでした：$error')));
      }
    }
  }

  void _moveChapter(int next) {
    if (next < 0 || next >= widget.chapters.length) return;
    setState(() => _index = next);
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.chapters[_index];
    final chapter = item.chapter;

    return ReaderPage(
      key: ValueKey(chapter.storageId),
      files: item.files,
      title: chapter.title,
      onOpened: () {
        unawaited(_remember(item));
      },
      progressKey: ReadingKey(
        sourceId: chapter.progressSourceId,
        chapterId: chapter.progressChapterId,
      ),
      onPreviousChapter:
          _index > 0 &&
              widget.chapters[_index - 1].chapter.workId == chapter.workId
          ? () => _moveChapter(_index - 1)
          : null,
      onNextChapter:
          _index + 1 < widget.chapters.length &&
              widget.chapters[_index + 1].chapter.workId == chapter.workId
          ? () => _moveChapter(_index + 1)
          : null,
    );
  }
}
