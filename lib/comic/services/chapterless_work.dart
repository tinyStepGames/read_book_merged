import 'package:dio/dio.dart';

import 'html_probe.dart';
import 'list_extraction_rule.dart';
import 'rule_browse_client.dart';
import 'site_reading_settings.dart';
import 'site_rule_store.dart';
import 'work_page_details.dart';

class ChapterlessWorkResult {
  const ChapterlessWorkResult({
    required this.pageUri,
    required this.details,
    required this.readUrl,
    this.readIssue,
  });

  final Uri pageUri;
  final WorkPageDetails details;
  final Uri? readUrl;
  final String? readIssue;
}

/// 常に選択した1作品だけを渡し、別作品を次の話にしない。
List<RuleBrowseItem> singleWorkReaderItems({
  required RuleBrowseItem item,
  Uri? readUrl,
}) {
  final target = readUrl ?? item.url;
  if (target == null) {
    throw const FormatException('読むURLがありません');
  }

  final url = htmlProbeUri(target.toString());

  return List<RuleBrowseItem>.unmodifiable([
    RuleBrowseItem(
      title: item.title,
      url: url,
      thumbnail: item.thumbnail,
      date: item.date,
      latestChapter: '',
      issues: const [],
    ),
  ]);
}

class ChapterlessWorkClient {
  ChapterlessWorkClient({RulePageFetcher? fetcher}) : _fetcher = fetcher;

  final RulePageFetcher? _fetcher;
  final HtmlProbeClient _client = HtmlProbeClient();

  void close() => _client.close();

  void _check(CancelToken token) {
    if (token.isCancelled) {
      throw StateError('作品詳細の取得を中止しました');
    }
  }

  Future<ChapterlessWorkResult> load({
    required SavedSiteRule site,
    required String targetUrl,
    required CancelToken cancelToken,
    RenderedRulePageFetcher? renderedFetcher,
  }) async {
    _check(cancelToken);

    final settings = site.readingSettings;
    if (settings == null || settings.mode != SiteReadingMode.details) {
      throw const FormatException('作品詳細から読む設定が必要です');
    }

    settings.validateFor(site.rules.values);

    final template = settings.detailsRule!;
    final origin = htmlProbeUri(template.pageUrl).origin;
    final target = htmlProbeUri(targetUrl);

    if (target.origin != origin) {
      throw const FormatException('選択した作品の取得元が設定と異なります');
    }

    final HtmlProbePage page;

    if (template.acquisition == 'renderedDom') {
      if (renderedFetcher == null) {
        throw const FormatException('表示後HTMLの取得処理が未接続です');
      }

      final selectors = <String>[
        for (final field in template.details.values)
          if (field.enabled && field.selector.trim().isNotEmpty) field.selector,
        if (settings.readLink != null) settings.readLink!.selector,
      ];

      page = await renderedFetcher(
        target.toString(),
        cancelToken: cancelToken,
        allowedOrigin: origin,
        groupSelector: selectors.isEmpty ? 'body' : selectors.join(', '),
      );
    } else {
      final fetcher = _fetcher;
      page = fetcher == null
          ? await _client.fetch(
              target.toString(),
              cancelToken: cancelToken,
              allowedOrigin: origin,
            )
          : await fetcher(
              target.toString(),
              cancelToken: cancelToken,
              allowedOrigin: origin,
            );
    }

    _check(cancelToken);

    final finalUri = htmlProbeUri(page.uri.toString());
    if (finalUri.origin != origin) {
      throw const FormatException('転送後の作品詳細が別の取得元です');
    }

    final effective = ListExtractionRule(
      pageUrl: finalUri.toString(),
      groupSelector: 'html',
      fields: defaultListFields(),
      acquisition: template.acquisition,
      details: Map.of(template.details),
    );

    final details = await extractWorkPageDetailsSafely(page, effective);
    _check(cancelToken);

    final link = settings.readLink;
    if (link == null) {
      return ChapterlessWorkResult(
        pageUri: finalUri,
        details: details,
        readUrl: finalUri,
      );
    }

    Uri? readUrl;
    String? readIssue;

    try {
      final fields = defaultListFields();
      fields['title'] = const ListFieldRule(selector: 'title');
      fields['url'] = link;

      final report = await extractListRowsSafely(
        page,
        ListExtractionRule(
          pageUrl: finalUri.toString(),
          groupSelector: 'html',
          fields: fields,
        ),
        maxRows: 1,
        collectCandidates: true,
      );

      _check(cancelToken);

      if (report.rows.length != 1) {
        throw const FormatException('読むリンクを抽出できませんでした');
      }

      final row = report.rows.single;
      final count = row.matchCounts['url'] ?? 0;

      if (count != 1) {
        throw FormatException('読むリンクが$count件です。1件に絞れるよう設定してください');
      }

      final issues = row.issues
          .where((issue) => issue.startsWith('リンク：'))
          .toList();

      if (issues.isNotEmpty) {
        throw FormatException(issues.join('\n'));
      }

      final candidate = htmlProbeUri(row.values['url'] ?? '');

      if (candidate.origin != origin) {
        throw const FormatException('読むリンクが別の取得元です');
      }

      readUrl = candidate;
    } catch (error) {
      _check(cancelToken);
      readIssue = '読むリンクを取得できませんでした：$error';
    }

    _check(cancelToken);

    return ChapterlessWorkResult(
      pageUri: finalUri,
      details: details,
      readUrl: readUrl,
      readIssue: readIssue,
    );
  }
}
