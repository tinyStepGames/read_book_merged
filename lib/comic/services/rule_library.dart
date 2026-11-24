import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../sources/source_adapter.dart';
import 'download_store.dart';
import 'html_probe.dart';
import 'rule_browse_client.dart';
import 'rule_downloads.dart';
import 'saved_download_repository.dart';
import 'site_rule_store.dart';
import 'site_reading_settings.dart';
import 'user_library_store.dart';

final _ruleLibrarySourcePattern = RegExp(r'^custom-site:([A-Za-z0-9_-]{22})$');

bool isRuleLibrarySource(String sourceId) =>
    _ruleLibrarySourcePattern.hasMatch(sourceId);

String ruleLibrarySiteId(String sourceId) {
  final match = _ruleLibrarySourcePattern.firstMatch(sourceId);
  if (match == null) {
    throw const FormatException('作成サイトの識別子が不正です');
  }
  return match.group(1)!;
}

String _workKey(String sourceId, String workId) =>
    jsonEncode([sourceId, workId]);

enum RuleLibraryHistoryDestination { chapters, details, reader }

RuleLibraryHistoryDestination ruleLibraryHistoryDestination(
  SavedSiteRule? site,
) => switch (site?.readingMode) {
  SiteReadingMode.chapters => RuleLibraryHistoryDestination.chapters,
  SiteReadingMode.details => RuleLibraryHistoryDestination.details,
  SiteReadingMode.direct || null => RuleLibraryHistoryDestination.reader,
};

class RuleLibraryWork {
  const RuleLibraryWork({
    required this.sourceId,
    required this.tab,
    required this.work,
  });

  final String sourceId;
  final SourceTab tab;
  final ComicWork work;
}

RuleLibraryWork ruleLibraryWork({
  required SavedSiteRule site,
  required String workUrl,
  required String title,
  Uri? thumbnail,
}) {
  final uri = htmlProbeUri(workUrl);
  final sourceId = 'custom-site:${site.id}';
  ruleLibrarySiteId(sourceId);

  for (final rule in site.rules.values) {
    if (htmlProbeUri(rule.pageUrl).origin != uri.origin) {
      throw const FormatException('作品とサイト設定の取得元が異なります');
    }
  }

  return RuleLibraryWork(
    sourceId: sourceId,
    tab: SourceTab(sourceId, site.name, const BrowseQuery()),
    work: ComicWork(
      id: uri.toString(),
      title: title.trim().isEmpty ? uri.toString() : title,
      url: uri,
      thumbnail: thumbnail?.toString(),
    ),
  );
}

ComicChapter ruleLibraryChapter({
  required RuleLibraryWork record,
  required RuleBrowseItem chapter,
}) {
  final url = chapter.url;
  if (url == null) {
    throw const FormatException('話のURLがありません');
  }

  return ruleSavedChapter(
    siteId: ruleLibrarySiteId(record.sourceId),
    workUrl: record.work.id,
    chapterUrl: url.toString(),
    title: chapter.title,
    publishedDateText: chapter.date,
  );
}

void validateRuleLibraryChapter(ComicChapter chapter) {
  final expected = ruleSavedChapter(
    siteId: ruleLibrarySiteId(chapter.sourceId),
    workUrl: chapter.workId,
    chapterUrl: chapter.url.toString(),
    title: chapter.title,
  );

  if (chapter.id != expected.id ||
      chapter.workId != expected.workId ||
      chapter.storageId != expected.storageId ||
      chapter.language != expected.language ||
      chapter.progressSourceId != expected.progressSourceId ||
      chapter.progressChapterId != expected.progressChapterId) {
    throw const FormatException('作成サイトの保存識別子が一致しません');
  }
}

String _navigationKey(RuleLibraryWork record) =>
    'rule-library-navigation-v1:${_workKey(record.sourceId, record.work.id)}';

Future<void> rememberRuleLibrary({
  required DownloadStore store,
  required RuleLibraryWork record,
  required RuleBrowseItem chapter,
  List<RuleBrowseItem> chapters = const [],
}) async {
  final saved = ruleLibraryChapter(record: record, chapter: chapter);

  await UserLibraryStore.forRoot(
    store.root,
  ).remember(record.sourceId, record.tab, record.work, saved);

  // 補助的な前後移動情報の保存失敗で、記録済みの履歴を失敗扱いにしない。
  if (chapters.isEmpty) return;

  try {
    await store.writeCache(_navigationKey(record), [
      for (final item in chapters.take(5000))
        if (item.url != null)
          {
            'title': item.title,
            'url': item.url.toString(),
            'thumbnail': item.thumbnail?.toString(),
            'date': item.date,
            'chapterNumber': item.chapterNumber,
          },
    ]);
  } catch (error) {
    debugPrint('[rule-library] navigation_cache_failed=$error');
  }
}

Future<List<RuleBrowseItem>> ruleLibraryNavigation({
  required DownloadStore store,
  required RuleLibraryWork record,
  required ComicChapter selected,
}) async {
  validateRuleLibraryChapter(selected);

  if (selected.sourceId != record.sourceId ||
      selected.workId != record.work.id) {
    throw const FormatException('作品と履歴が一致しません');
  }

  final items = <RuleBrowseItem>[];
  final seen = <String>{};

  try {
    final cached = await store.readCache(_navigationKey(record));

    if (cached is List) {
      for (final raw in cached.take(5000)) {
        try {
          final data = Map<String, dynamic>.from(raw as Map);
          final url = htmlProbeUri(data['url'] as String);
          if (url.origin != record.work.url.origin) continue;
          if (!seen.add(url.toString())) continue;

          final thumbnail = data['thumbnail'];

          items.add(
            RuleBrowseItem(
              title: data['title'] as String,
              url: url,
              thumbnail: thumbnail is String ? htmlProbeUri(thumbnail) : null,
              date: data['date'] as String? ?? '',
              latestChapter: '',
              chapterNumber: data['chapterNumber'] as String? ?? '',
              issues: const [],
            ),
          );
        } catch (_) {
          // 壊れた補助情報は使わず、履歴の対象話は下で必ず補う。
        }
      }
    }
  } catch (_) {
    // 補助キャッシュがなくても、履歴の対象URLを使用する。
  }

  if (!items.any((item) => item.url.toString() == selected.url.toString())) {
    return [
      RuleBrowseItem(
        title: selected.title,
        url: selected.url,
        thumbnail: record.work.thumbnail == null
            ? null
            : htmlProbeUri(record.work.thumbnail!),
        date: selected.publishedDateText ?? '',
        latestChapter: '',
        issues: const [],
      ),
    ];
  }

  return List.unmodifiable(items);
}

/// 保存済みの検査・削除・オフライン読書専用。ネットワーク取得はしない。
class RuleLibraryOfflineAdapter extends SourceAdapter {
  RuleLibraryOfflineAdapter(this.id) {
    ruleLibrarySiteId(id);
  }

  @override
  final String id;

  @override
  String get name => '作成サイト';

  @override
  List<SourceTab> get defaultTabs => const [];

  @override
  Future<List<SourceTab>> discoverTabs() async => const [];

  @override
  Future<List<ComicWork>> fetchWorks(BrowseQuery query) async =>
      throw UnsupportedError('保存済み専用です');

  @override
  Future<List<ComicChapter>> fetchChapters(
    ComicWork work,
    BrowseQuery query,
  ) async => throw UnsupportedError('保存済み専用です');

  @override
  Future<ChapterContent> fetchContent(ComicChapter chapter) async =>
      throw UnsupportedError('保存済み専用です');

  @override
  ComicChapter? restoreChapter(Map<String, dynamic> data) => null;

  @override
  void close() {}
}

class RuleLibrarySavedGroup {
  const RuleLibrarySavedGroup({
    required this.key,
    required this.record,
    required this.items,
  });

  final String key;
  final RuleLibraryWork record;
  final List<SavedChapter> items;
}

class RuleLibrarySavedResult {
  const RuleLibrarySavedResult(this.groups, this.issues);

  final List<RuleLibrarySavedGroup> groups;
  final List<String> issues;
}

Map<String, List<SavedChapter>> groupRuleLibraryChapters(
  Iterable<SavedChapter> chapters,
) {
  final groups = <String, List<SavedChapter>>{};

  for (final item in chapters) {
    validateRuleLibraryChapter(item.chapter);
    groups.putIfAbsent(savedWorkKey(item.chapter), () => []).add(item);
  }

  return groups;
}

Future<RuleLibrarySavedResult> loadRuleLibrarySaved(DownloadStore store) async {
  final warnings = <String>[];
  final sites = <String, SavedSiteRule>{};

  try {
    for (final site in await SiteRuleStore(store.root).load()) {
      sites[site.id] = site;
    }
  } catch (error) {
    warnings.add('サイト名を読み込めませんでした：$error');
  }

  final sourceIds = <String>{for (final id in sites.keys) 'custom-site:$id'};

  // 設定を削除したサイトでも、保存画像は見つけられるようにする。
  // メタデータだけを読み、画像の検証は既存のscanへ委ねる。
  await store.root.create(recursive: true);

  await for (final entry in store.root.list(followLinks: false)) {
    if (entry is! Directory) continue;

    final manifest = File(p.join(entry.path, 'manifest.json'));

    try {
      if (await FileSystemEntity.type(manifest.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }

      if (await manifest.length() > 512 * 1024) continue;

      final data = jsonDecode(await manifest.readAsString());
      if (data is! Map || data['chapter'] is! Map) continue;

      final sourceId = (data['chapter'] as Map)['sourceId'];

      if (sourceId is String && isRuleLibrarySource(sourceId)) {
        sourceIds.add(sourceId);
      }
    } catch (_) {
      // 詳細な保存検査と警告は既存のscanに任せる。
    }
  }

  final metadata = <String, LibraryItem>{};

  try {
    final library = UserLibraryStore.forRoot(store.root);
    await library.load();

    for (final item in [
      ...library.history.reversed,
      ...library.favorites.reversed,
    ]) {
      if (isRuleLibrarySource(item.sourceId)) {
        metadata[_workKey(item.sourceId, item.work.id)] = item;
      }
    }
  } catch (error) {
    warnings.add('作品名の補助情報を読み込めませんでした：$error');
  }

  final downloads = RuleDownloads(store);
  final groups = <RuleLibrarySavedGroup>[];

  for (final sourceId in sourceIds) {
    final siteId = ruleLibrarySiteId(sourceId);

    try {
      final scan = await downloads.scan(siteId);
      warnings.addAll(scan.issues);

      for (final entry in groupRuleLibraryChapters(scan.chapters).entries) {
        final chapter = entry.value.first.chapter;
        final known = metadata[_workKey(sourceId, chapter.workId)];
        final siteName =
            sites[siteId]?.name ??
            known?.tab.title ??
            '削除済みサイト（${siteId.substring(0, 6)}）';

        final title = known?.work.title ?? await downloads.workTitle(chapter);

        final record = RuleLibraryWork(
          sourceId: sourceId,
          tab: SourceTab(sourceId, siteName, const BrowseQuery()),
          work: ComicWork(
            id: chapter.workId,
            title: title,
            url: htmlProbeUri(chapter.workId),
            thumbnail: known?.work.thumbnail,
          ),
        );

        groups.add(
          RuleLibrarySavedGroup(
            key: entry.key,
            record: record,
            items: List.unmodifiable(entry.value),
          ),
        );
      }
    } catch (error) {
      warnings.add('${sites[siteId]?.name ?? sourceId}：$error');
    }
  }

  return RuleLibrarySavedResult(
    List.unmodifiable(groups),
    List.unmodifiable(warnings.toSet()),
  );
}
