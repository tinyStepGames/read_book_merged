import 'list_extraction_rule.dart';
import 'site_browse_tab.dart';
import 'site_rule_store.dart';

SavedSiteRule makeSiteBrowseTabPlan(SavedSiteRule site, SiteBrowseTab tab) {
  tab.validateFor(site.rules);

  final ListExtractionRule source;

  switch (tab.ruleSource) {
    case 'custom':
      source = tab.customRule!;
    case 'tags':
      source = site.tagNavigation?.rule ?? site.rules['works']!;
    default:
      source = site.rules['works']!;
  }

  final effective = ListExtractionRule(
    pageUrl: tab.pageUrl,
    groupSelector: source.groupSelector,
    fields: Map.of(source.fields),
    details: Map.of(source.details),
    kind: 'works',
    acquisition: source.acquisition,
    paginationUrl: tab.paginationUrl,
  );

  effective.validate();

  return SavedSiteRule(
    id: site.id,
    name: site.name,
    updatedAt: site.updatedAt,
    rules: {...site.rules, 'works': effective},
    images: site.images,
    tagNavigation: site.tagNavigation,
    searchSettings: site.searchSettings,
    browseTabs: site.browseTabs,
    readingSettings: site.readingSettings,
  );
}
