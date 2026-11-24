import 'services/rule_video_support.dart';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'services/chapter_reading_order.dart';
import 'services/html_probe.dart';
import 'services/rule_browse_client.dart';
import 'services/rule_downloads.dart';
import 'services/site_rule_store.dart';
import 'sources/source_adapter.dart';

class RuleBatchDownloadPanel extends StatefulWidget {
  const RuleBatchDownloadPanel({
    super.key,
    required this.site,
    required this.workUrl,
    required this.workTitle,
    required this.items,
  });

  final SavedSiteRule site;
  final String workUrl;
  final String workTitle;
  final List<RuleBrowseItem> items;

  @override
  State<RuleBatchDownloadPanel> createState() => _RuleBatchDownloadPanelState();
}

class _RuleBatchDownloadPanelState extends State<RuleBatchDownloadPanel> {
  RuleDownloads? _downloads;
  String? _error;
  bool _confirming = false;

  String get _scope =>
      jsonEncode([widget.site.id, htmlProbeUri(widget.workUrl).toString()]);

  @override
  void initState() {
    super.initState();
    _attach();
  }

  Future<void> _attach() async {
    if (usesRuleVideo(widget.site)) return;
    try {
      final downloads = await RuleDownloads.open();
      if (!mounted) return;

      _downloads = downloads;
      downloads.batch.state.addListener(_changed);
      downloads.state.addListener(_changed);
      setState(() {});
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _downloads?.batch.state.removeListener(_changed);
    _downloads?.state.removeListener(_changed);
    super.dispose();
  }

  Future<void> _start() async {
    final downloads = _downloads;
    if (downloads == null || downloads.isBusy || _confirming) return;

    setState(() {
      _confirming = true;
      _error = null;
    });

    try {
      final seen = <String>{};
      final chapters = <ComicChapter>[];
      var invalid = 0;
      var duplicates = 0;

      // 昇順・降順の表示設定とは独立して、読書順に処理する。
      final items = chapterReadingOrder<RuleBrowseItem>(
        widget.items,
        titleOf: (item) => item.title,
        explicitNumberOf: (item) => item.chapterNumber,
      );

      for (final item in items) {
        final url = item.url;
        if (url == null) {
          invalid++;
          continue;
        }

        try {
          final chapter = ruleSavedChapter(
            siteId: widget.site.id,
            workUrl: widget.workUrl,
            chapterUrl: url.toString(),
            title: item.title,
            publishedDateText: item.date,
          );

          if (!seen.add(chapter.storageId)) {
            duplicates++;
            continue;
          }

          chapters.add(chapter);
        } catch (_) {
          invalid++;
        }
      }

      if (chapters.isEmpty) {
        setState(() => _error = '保存できるチャプターがありません。URL設定を確認してください。');
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('未保存の話を一括保存'),
          content: SingleChildScrollView(
            child: Text(
              [
                widget.workTitle.isEmpty ? '現在の作品' : widget.workTitle,
                '',
                '取得済みの一覧から ${chapters.length} 話を確認します。',
                '保存済みはスキップし、未保存・未完了の話を順番に処理します。',
                if (invalid > 0) 'URL不正などで対象外：$invalid 件',
                if (duplicates > 0) '重複のため除外：$duplicates 件',
                '',
                'まだ取得していないチャプターページは対象外です。',
                '保存が許可されているコンテンツで実行してください。',
                'アプリがバックグラウンドになると、処理が止まる場合があります。',
              ].join('\n'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('開始'),
            ),
          ],
        ),
      );

      if (!mounted || confirmed != true) return;

      // 確認ダイアログを開いている間に別の保存が始まった場合も、
      // サービス側で重複開始を拒否する。
      await downloads.saveBatch(
        site: widget.site,
        workUrl: widget.workUrl,
        workTitle: widget.workTitle,
        chapters: chapters,
      );
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (usesRuleVideo(widget.site)) return const SizedBox.shrink();
    final downloads = _downloads;
    final batch = downloads?.batch.state.value;
    final mine = batch != null && batch.scope == _scope;
    final active = mine && batch.running;
    final busy = downloads?.isBusy ?? true;
    final hasResult = mine && batch.total > 0;
    final transfer = downloads?.state.value;

    final String summary;
    if (active) {
      summary = batch.stopping
          ? '停止処理中'
          : '${batch.processed} / ${batch.total} 話を処理済み';
    } else if (hasResult) {
      summary = [
        batch.stopped ? '停止しました' : '処理が完了しました',
        '保存 ${batch.saved}',
        '保存済み ${batch.skipped}',
        '失敗 ${batch.failures.length}',
      ].join(' ・ ');
    } else if (busy && downloads != null) {
      summary = '別のダウンロードを実行中です';
    } else {
      summary = '保存済みを除き、取得済みの話を順番に保存します';
    }

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '作品のオフライン保存',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (active)
                  TextButton.icon(
                    onPressed: batch.stopping ? null : downloads!.stop,
                    icon: const Icon(Icons.pause),
                    label: const Text('停止'),
                  )
                else
                  TextButton.icon(
                    onPressed:
                        downloads == null ||
                            busy ||
                            _confirming ||
                            widget.site.images == null ||
                            widget.items.isEmpty
                        ? null
                        : _start,
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('未保存を一括保存'),
                  ),
              ],
            ),
            SizedBox(
              height: 48,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    active
                        ? [
                            batch.currentTitle,
                            if (transfer?.running == true) transfer!.message,
                          ].join(' ・ ')
                        : '画像は最大4件並列。中断後は再実行で再開できます。',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 3,
              child: active
                  ? LinearProgressIndicator(
                      value: batch.total > 0
                          ? batch.processed / batch.total
                          : null,
                    )
                  : null,
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  _error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
            if (hasResult && batch.failures.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text('失敗した話：${batch.failures.length}件'),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SelectableText(batch.failures.join('\n\n')),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
