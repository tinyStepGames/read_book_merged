import 'package:dio/dio.dart';

import 'html_probe.dart';
import 'list_extraction_rule.dart';
import 'site_rule_store.dart';
import 'site_reading_settings.dart';
import 'work_page_details.dart';
import 'page_url_template.dart';

typedef RulePageFetcher =
    Future<HtmlProbePage> Function(
      String input, {
      required CancelToken cancelToken,
      required String allowedOrigin,
    });

typedef RenderedRulePageFetcher =
    Future<HtmlProbePage> Function(
      String input, {
      required CancelToken cancelToken,
      required String allowedOrigin,
      required String groupSelector,
    });

class RuleBrowseItem {
  const RuleBrowseItem({
    required this.title,
    required this.url,
    required this.thumbnail,
    required this.date,
    required this.latestChapter,
    required this.issues,
    this.chapterNumber = '',
  });

  final String title;
  final Uri? url;
  final Uri? thumbnail;
  final String date;
  final String latestChapter;
  final List<String> issues;
  final String chapterNumber;
}

class RuleBrowseResult {
  const RuleBrowseResult({
    required this.pageUri,
    required this.total,
    required this.items,
    this.workDetails = const WorkPageDetails(),
  });

  final Uri pageUri;
  final int total;
  final List<RuleBrowseItem> items;
  final WorkPageDetails workDetails;
}

class RuleBrowseClient {
  RuleBrowseClient({RulePageFetcher? fetcher}) : _fetcher = fetcher;

  final HtmlProbeClient _client = HtmlProbeClient();
  final RulePageFetcher? _fetcher;

  static const maxRows = 5000;

  void _checkCancelled(CancelToken token) {
    if (token.isCancelled) throw StateError('取得を中止しました');
  }

  Future<RuleBrowseResult> load({
    required SavedSiteRule site,
    required String kind,
    required CancelToken cancelToken,
    String? targetUrl,
    int? pageNumber,
    RenderedRulePageFetcher? renderedFetcher,
  }) async {
    _checkCancelled(cancelToken);

    if (!const ['works', 'chapters'].contains(kind)) {
      throw const FormatException('未対応の一覧の種類です');
    }

    final template = site.rules[kind];
    if (template == null) {
      throw StateError(
        '${kind == 'works' ? '作品一覧' : 'チャプター一覧'}が未設定です。'
        'サイトルール管理で設定してください',
      );
    }

    template.validate();
    if (template.kind != kind) {
      throw const FormatException('保存先と一覧ルールの種類が一致しません');
    }
    if (template.acquisition == 'renderedDom' && renderedFetcher == null) {
      throw const FormatException('表示後HTMLの取得画面が接続されていません');
    }

    if (kind == 'chapters' && (targetUrl == null || targetUrl.trim().isEmpty)) {
      throw const FormatException('作品のURLが必要です。サンプルURLを代わりに使用することはできません');
    }

    final sample = htmlProbeUri(template.pageUrl);

    final pagination = template.paginationUrl.isEmpty
        ? null
        : PageUrlTemplate(template.paginationUrl);

    if (pageNumber != null &&
        (kind != 'works' || pagination == null || targetUrl != null)) {
      throw const FormatException('この取得条件ではページ番号を指定できません');
    }

    final target = htmlProbeUri(
      targetUrl ??
          (kind == 'works' && pagination != null
              ? pagination.url(pageNumber ?? pagination.start)
              : template.pageUrl),
    );

    if (target.origin != sample.origin) {
      throw const FormatException(
        '選択したURLと、この一覧設定の取得元が異なります。'
        'サブドメイン・www・ポート番号も含めて設定を確認してください',
      );
    }

    final page = template.acquisition == 'renderedDom'
        ? await renderedFetcher!(
            target.toString(),
            cancelToken: cancelToken,
            allowedOrigin: target.origin,
            groupSelector: template.groupSelector,
          )
        : _fetcher == null
        ? await _client.fetch(
            target.toString(),
            cancelToken: cancelToken,
            allowedOrigin: target.origin,
          )
        : await _fetcher(
            target.toString(),
            cancelToken: cancelToken,
            allowedOrigin: target.origin,
          );

    _checkCancelled(cancelToken);

    final finalUri = htmlProbeUri(page.uri.toString());
    if (finalUri.origin != target.origin) {
      throw const FormatException('取得結果が別の取得元になっています');
    }

    // 保存されたサンプルURLではなく、今回取得したページへルールを適用。
    // 末尾スラッシュなど、同じ取得元内の転送後URLもここで反映する。
    final effectiveRule = ListExtractionRule(
      pageUrl: finalUri.toString(),
      groupSelector: template.groupSelector,
      fields: Map.of(template.fields),
      kind: template.kind,
      acquisition: template.acquisition,
      details: Map.of(template.details),
    );

    final report = await extractListRowsSafely(
      page,
      effectiveRule,
      maxRows: maxRows,
    );
    _checkCancelled(cancelToken);

    if (report.total > maxRows) {
      throw const FormatException('一覧が5000件を超えました。取得範囲やページ分割の設定が必要です');
    }

    var workDetails = const WorkPageDetails();
    if (kind == 'chapters' && effectiveRule.details.isNotEmpty) {
      try {
        workDetails = await extractWorkPageDetailsSafely(page, effectiveRule);
      } catch (error) {
        workDetails = WorkPageDetails(issues: ['作品詳細：$error']);
      }
    }
    _checkCancelled(cancelToken);

    final nextTemplate =
        kind == 'works' && site.readingMode == SiteReadingMode.chapters
        ? site.rules['chapters']
        : null;
    final linkOrigin = nextTemplate == null
        ? finalUri.origin
        : htmlProbeUri(nextTemplate.pageUrl).origin;

    final items = <RuleBrowseItem>[];

    for (var index = 0; index < report.rows.length; index++) {
      final row = report.rows[index];

      // Empty work layout slots:
      // 完全に空の作品枠だけを、通常の閲覧一覧から除外する。
      // 抽出レポート自体は変更せず、設定画面の診断を維持する。
      // 片方だけ欠落した項目や、処理エラーのある項目は残す。
      final emptyWorkSlot =
          kind == 'works' &&
          (row.values['title'] ?? '').trim().isEmpty &&
          (row.values['url'] ?? '').trim().isEmpty &&
          row.values.values.every((value) => value.trim().isEmpty) &&
          row.issues.every(
            (issue) => issue == 'タイトル：取得できません' || issue == 'リンク：取得できません',
          );

      if (emptyWorkSlot) continue;

      final issues = List<String>.of(row.issues);
      final title = row.values['title']?.trim() ?? '';
      Uri? url;

      try {
        final candidate = htmlProbeUri(row.values['url'] ?? '');
        if (candidate.origin != linkOrigin) {
          throw const FormatException('次の取得設定とは異なる取得元のリンクです');
        }
        url = candidate;
      } catch (error) {
        issues.add('リンクを開けません：$error');
      }

      if (title.isEmpty) {
        issues.add('タイトルが空です');
        url = null;
      }

      Uri? thumbnail;
      final rawThumbnail = row.values['thumbnail'] ?? '';
      if (rawThumbnail.isNotEmpty) {
        try {
          thumbnail = htmlProbeUri(rawThumbnail);
        } catch (_) {
          issues.add('表紙は認証情報を含まないHTTPSのURLにしてください');
        }
      }

      items.add(
        RuleBrowseItem(
          title: title.isEmpty ? 'タイトル未取得' : title,
          url: url,
          thumbnail: thumbnail,
          date: row.values['date'] ?? '',
          latestChapter: row.values['latestChapter'] ?? '',
          chapterNumber: index < workDetails.chapterNumbers.length
              ? workDetails.chapterNumbers[index]
              : '',
          issues: List.unmodifiable(issues),
        ),
      );
    }

    return RuleBrowseResult(
      pageUri: finalUri,
      total: report.total,
      items: List.unmodifiable(items),
      workDetails: workDetails,
    );
  }

  void close() => _client.close();
}
