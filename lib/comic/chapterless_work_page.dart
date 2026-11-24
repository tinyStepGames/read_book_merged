import 'video_download_page.dart';
import 'services/rule_video_support.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'rule_browse_page.dart';
import 'rule_download_button.dart';
import 'rule_online_reader_page.dart';
import 'rule_library_widgets.dart';
import 'services/chapterless_work.dart';
import 'services/headless_download_page.dart';
import 'services/html_probe.dart';
import 'services/rule_browse_client.dart';
import 'services/rule_diagnostics.dart';
import 'services/rule_downloads.dart';
import 'services/site_rule_store.dart';
import 'services/tag_browse_plan.dart';
import 'services/work_page_details.dart';
import 'services/work_tag_link.dart';
import 'work_details_panel.dart';

Future<HtmlProbePage> fetchChapterlessRendered(
  String input, {
  required CancelToken cancelToken,
  required String allowedOrigin,
  required String groupSelector,
}) => fetchRenderedDownloadPage(
  input,
  cancelToken: cancelToken,
  allowedOrigin: allowedOrigin,
  groupSelector: groupSelector,
);

class ChapterlessReaderPage extends StatelessWidget {
  const ChapterlessReaderPage({
    super.key,
    required this.site,
    required this.item,
    required this.workUrl,
    this.readUrl,
  });

  final SavedSiteRule site;
  final RuleBrowseItem item;
  final Uri workUrl;
  final Uri? readUrl;

  @override
  Widget build(BuildContext context) {
    if (!canOpenRuleContent(site)) {
      return Scaffold(
        appBar: AppBar(title: Text(item.title)),
        body: const Padding(
          padding: EdgeInsets.all(24),
          child: SelectableText(
            '本文画像ルールが未設定です。\n'
            'サイトルール管理の「本文画像」から設定してください。\n'
            'チャプター一覧の設定は不要です。',
          ),
        ),
      );
    }

    final chapters = singleWorkReaderItems(item: item, readUrl: readUrl);
    final target = chapters.single.url!;

    return Stack(
      fit: StackFit.expand,
      children: [
        RuleOnlineReaderPage(
          site: site,
          chapters: chapters,
          initialIndex: 0,
          workThumbnail: item.thumbnail,
          workUrl: workUrl.toString(),
          workTitle: item.title,
        ),
        if (!usesRuleVideo(site))
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: Material(
                color: Colors.black87,
                shape: const CircleBorder(),
                child: RuleDownloadButton(
                  site: site,
                  chapter: ruleSavedChapter(
                    siteId: site.id,
                    workUrl: workUrl.toString(),
                    chapterUrl: target.toString(),
                    title: item.title,
                    publishedDateText: item.date,
                  ),
                  workTitle: item.title,
                  renderedFetcher: fetchChapterlessRendered,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class ChapterlessDetailsPage extends StatefulWidget {
  const ChapterlessDetailsPage({
    super.key,
    required this.site,
    required this.item,
    this.resumeChapter,
  });

  final SavedSiteRule site;
  final RuleBrowseItem item;
  final RuleBrowseItem? resumeChapter;

  @override
  State<ChapterlessDetailsPage> createState() => _ChapterlessDetailsPageState();
}

class _ChapterlessDetailsPageState extends State<ChapterlessDetailsPage> {
  final _client = ChapterlessWorkClient();
  CancelToken? _cancel;
  ChapterlessWorkResult? _result;
  String? _error;
  bool _busy = true;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  @override
  void dispose() {
    _cancel?.cancel('画面を閉じました');
    _client.close();
    super.dispose();
  }

  Future<void> _load() async {
    _cancel?.cancel('再取得');

    final token = CancelToken();
    _cancel = token;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final url = widget.item.url;
      if (url == null) {
        throw const FormatException('作品のURLがありません');
      }

      final result = await _client.load(
        site: widget.site,
        targetUrl: url.toString(),
        cancelToken: token,
        renderedFetcher: fetchChapterlessRendered,
      );

      if (!mounted || token.isCancelled) return;
      setState(() => _result = result);
    } catch (error) {
      if (!mounted || token.isCancelled) return;

      setState(() {
        _error = ruleFailureMessage(error, stage: RuleDiagnosticStage.browsing);
      });
    } finally {
      if (mounted && identical(_cancel, token)) {
        setState(() => _busy = false);
      }
    }
  }

  RuleBrowseItem _readerItem() {
    final details = _result?.details;

    return RuleBrowseItem(
      title: details == null || details.title.isEmpty
          ? widget.item.title
          : details.title,
      url: _result?.readUrl,
      thumbnail: details?.thumbnail ?? widget.item.thumbnail,
      date: widget.item.date,
      latestChapter: '',
      issues: const [],
    );
  }

  Future<void> _read() async {
    final result = _result;
    final readUrl = widget.resumeChapter?.url ?? result?.readUrl;

    if (_busy || _opening || readUrl == null) {
      return;
    }

    _opening = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChapterlessReaderPage(
            site: widget.site,
            item: _readerItem(),
            workUrl: result?.pageUri ?? widget.item.url!,
            readUrl: readUrl,
          ),
        ),
      );
    } finally {
      _opening = false;
    }
  }

  Future<void> _tag(WorkTagLink tag) async {
    if (_busy || _opening) return;

    _opening = true;
    try {
      final plan = await makeTagBrowsePlanSafely(widget.site, tag);
      if (!mounted) return;

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RuleBrowsePage(
            site: plan.site,
            navigationSite: widget.site,
            listTitle: tag.label,
            pagingNotice: plan.notice,
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('タグ一覧を開けませんでした：$error')));
      }
    } finally {
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final canRead =
        !_busy &&
        (widget.resumeChapter?.url ?? result?.readUrl) != null &&
        canOpenRuleContent(widget.site);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.item.title),
        actions: [
          if (widget.item.url != null)
            RuleLibraryFavoriteButton(
              site: widget.site,
              workUrl: widget.item.url.toString(),
              title: _result?.details.title.isNotEmpty == true
                  ? _result!.details.title
                  : widget.item.title,
              thumbnail: _result?.details.thumbnail ?? widget.item.thumbnail,
            ),
          IconButton(
            tooltip: '再読み込み',
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Text('作品詳細を取得しています…'),
            ),
          if (_error != null) ...[
            SelectableText(
              _error!,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
            const SizedBox(height: 12),
          ],
          WorkDetailsPanel(
            details: result?.details ?? const WorkPageDetails(),
            fallbackTitle: widget.item.title,
            fallbackThumbnail: widget.item.thumbnail,
            onTagTap: _tag,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('chapterless-read'),
                  onPressed: canRead ? _read : null,
                  icon: const Icon(Icons.menu_book_outlined),
                  label: Text(widget.resumeChapter == null ? '読む' : '続きを読む'),
                ),
              ),
              if (canRead &&
                  usesRuleVideo(widget.site) &&
                  (result?.pageUri ?? widget.item.url) != null)
                VideoDownloadButton(
                  site: widget.site,
                  workUrl: (result?.pageUri ?? widget.item.url)!.toString(),
                  chapterUrl: (widget.resumeChapter?.url ?? result?.readUrl)!
                      .toString(),
                  title: _readerItem().title,
                  workTitle: _readerItem().title,
                  enabled: !_opening,
                ),
              if (result != null &&
                  result.readUrl != null &&
                  widget.site.images != null &&
                  !usesRuleVideo(widget.site))
                RuleDownloadButton(
                  site: widget.site,
                  chapter: ruleSavedChapter(
                    siteId: widget.site.id,
                    workUrl: result.pageUri.toString(),
                    chapterUrl: result.readUrl.toString(),
                    title: _readerItem().title,
                    publishedDateText: widget.item.date,
                  ),
                  workTitle: _readerItem().title,
                  renderedFetcher: fetchChapterlessRendered,
                ),
            ],
          ),
          if (!canOpenRuleContent(widget.site))
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Text(
                '読むにはサイトルール管理で「本文画像」を設定してください。'
                'チャプター一覧の設定は不要です。',
              ),
            ),
          if (result != null && result.readIssue != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: SelectableText(
                result.readIssue!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          if (result != null)
            for (final issue in result.details.issues.where(
              (issue) => !RegExp(r'^作品の表紙：\d+件あるため先頭を使用$').hasMatch(issue),
            ))
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  ruleIssueMessage(issue),
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ),
        ],
      ),
    );
  }
}
