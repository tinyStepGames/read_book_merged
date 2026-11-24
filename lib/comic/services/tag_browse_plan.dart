import 'tag_navigation_settings.dart';
import 'html_probe.dart';
import 'list_extraction_rule.dart';
import 'page_url_template.dart';
import 'site_rule_store.dart';
import 'work_tag_link.dart';

class TagBrowsePlan {
  const TagBrowsePlan({required this.site, this.notice});

  final SavedSiteRule site;
  final String? notice;
}

String? _rebasePagination(ListExtractionRule works, Uri target) {
  if (works.paginationUrl.isEmpty) return '';

  final original = PageUrlTemplate(works.paginationUrl);
  original.validateOrigin(works.pageUrl);

  final marker = RegExp(r'\{page;(\d+)\}').firstMatch(original.template)!;

  const token = 'ocrtagpageplaceholderqz';

  if (original.template.contains(token) || target.toString().contains(token)) {
    return null;
  }

  final source = htmlProbeUri(works.pageUrl);

  final templateUri = Uri.parse(
    original.template.replaceRange(marker.start, marker.end, token),
  );

  final query = <String, List<String>>{
    for (final entry in target.queryParametersAll.entries)
      entry.key: List.of(entry.value),
  };

  // クエリ方式：
  // タグのパスと既存の検索条件を維持して、
  // ページ番号のパラメーターだけを適用する。
  final pageEntries = templateUri.queryParametersAll.entries
      .where((entry) => entry.value.any((value) => value.contains(token)))
      .toList();

  if (pageEntries.length == 1) {
    final entry = pageEntries.single;
    query[entry.key] = List.of(entry.value);

    final result = target
        .replace(queryParameters: query)
        .toString()
        .replaceAll(token, marker.group(0)!);

    PageUrlTemplate(result).validateOrigin(target.toString());

    return result;
  }

  // パス方式：
  // /list/ → /list/page/{page;1}/ のように、
  // 元の一覧パスに追加された部分だけをタグ側へ移す。
  final sourcePrefix = source.path.replaceFirst(RegExp(r'/+$'), '');
  final targetPrefix = target.path.replaceFirst(RegExp(r'/+$'), '');

  if (templateUri.path.contains(token) &&
      templateUri.path.startsWith('$sourcePrefix/')) {
    final suffix = templateUri.path.substring(sourcePrefix.length);

    final result = target
        .replace(path: '$targetPrefix$suffix')
        .toString()
        .replaceAll(token, marker.group(0)!);

    PageUrlTemplate(result).validateOrigin(target.toString());

    return result;
  }

  // 判断できない形式では、通常一覧へ勝手に戻さない。
  return null;
}

TagBrowsePlan makeTagBrowsePlan(
  SavedSiteRule site,
  WorkTagLink tag, {
  Uri? resolvedTarget,
}) {
  final works = site.tagNavigation?.rule ?? site.rules['works'];

  if (works == null) {
    throw const FormatException(
      '作品一覧が未設定です。'
      '先に作品一覧ルールを保存してください',
    );
  }

  works.validate();

  final sample = htmlProbeUri(works.pageUrl);
  final target =
      resolvedTarget ??
      tagNavigationTargetUri(
        htmlProbeUri(tag.url.toString()),
        allowedOrigin: sample.origin,
        pattern: site.tagNavigation?.urlPattern ?? '',
        replacement: site.tagNavigation?.urlReplacement ?? '',
      );

  if (target.origin != sample.origin) {
    throw const FormatException('タグURLと作品一覧ルールの取得元が異なります');
  }

  final pagination = _rebasePagination(works, target);

  final tagRule = ListExtractionRule(
    pageUrl: target.toString(),
    groupSelector: works.groupSelector,
    fields: Map.of(works.fields),
    kind: 'works',
    acquisition: works.acquisition,
    details: Map.of(works.details),
    paginationUrl: pagination ?? '',
  );

  tagRule.validate();

  return TagBrowsePlan(
    site: SavedSiteRule(
      id: site.id,
      name: site.name,
      rules: {...site.rules, 'works': tagRule},
      updatedAt: site.updatedAt,
      images: site.images,
      tagNavigation: site.tagNavigation,
      searchSettings: site.searchSettings,
      browseTabs: site.browseTabs,
      readingSettings: site.readingSettings,
    ),
    notice: pagination == null
        ? 'このページ送り形式はタグURLへ安全に適用できないため、'
              'タグ一覧は先頭ページのみ表示しています。'
        : null,
  );
}

/// 画面からはこの関数を使い、URLの正規表現を別Isolateで実行する。
Future<TagBrowsePlan> makeTagBrowsePlanSafely(
  SavedSiteRule site,
  WorkTagLink tag,
) async {
  final rule = site.tagNavigation?.rule ?? site.rules['works'];

  if (rule == null) {
    throw const FormatException('先に作品一覧ルールを保存してください');
  }

  rule.validate();

  final target = await resolveTagNavigationUrl(
    input: tag.url,
    allowedOrigin: htmlProbeUri(rule.pageUrl).origin,
    pattern: site.tagNavigation?.urlPattern ?? '',
    replacement: site.tagNavigation?.urlReplacement ?? '',
  );

  return makeTagBrowsePlan(site, tag, resolvedTarget: target);
}
