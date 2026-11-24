import 'html_probe.dart';
import 'list_extraction_rule.dart';
import 'site_rule_store.dart';

SavedSiteRule makeSiteSearchPlan(SavedSiteRule site, String keyword) {
  final settings = site.searchSettings;

  if (settings == null) {
    throw const FormatException('検索設定が未設定です');
  }

  settings.validateFor(site.rules);

  final source =
      settings.rule ?? site.tagNavigation?.rule ?? site.rules['works']!;
  final template = settings.template;
  final target = htmlProbeUri(template.url(keyword));

  final effective = ListExtractionRule(
    pageUrl: target.toString(),
    groupSelector: source.groupSelector,
    fields: Map.of(source.fields),
    kind: 'works',
    acquisition: source.acquisition,
    details: Map.of(source.details),
    paginationUrl: template.paginationUrl(keyword),
  );

  effective.validate();

  return SavedSiteRule(
    id: site.id,
    name: site.name,
    updatedAt: site.updatedAt,
    rules: {...site.rules, 'works': effective},
    images: site.images,
    tagNavigation: site.tagNavigation,
    searchSettings: settings,
    browseTabs: site.browseTabs,
    readingSettings: site.readingSettings,
  );
}
