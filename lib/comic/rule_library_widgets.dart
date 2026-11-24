import 'services/rule_video_support.dart';
import 'package:flutter/material.dart';

import 'chapter_reader_page.dart';
import 'chapterless_work_page.dart';
import 'library_widgets.dart';
import 'rule_browse_page.dart';
import 'rule_online_reader_page.dart';
import 'services/download_store.dart';
import 'services/html_probe.dart';
import 'services/rule_browse_client.dart';
import 'services/rule_downloads.dart';
import 'services/rule_library.dart';
import 'services/site_reading_settings.dart';
import 'services/site_rule_store.dart';
import 'services/user_library_store.dart';

class RuleLibraryFavoriteButton extends StatelessWidget {
  const RuleLibraryFavoriteButton({
    super.key,
    required this.site,
    required this.workUrl,
    required this.title,
    this.thumbnail,
  });

  final SavedSiteRule site;
  final String workUrl;
  final String title;
  final Uri? thumbnail;

  @override
  Widget build(BuildContext context) {
    final record = ruleLibraryWork(
      site: site,
      workUrl: workUrl,
      title: title,
      thumbnail: thumbnail,
    );

    return FutureBuilder<RuleDownloads>(
      future: RuleDownloads.open(),
      builder: (context, snapshot) {
        final downloads = snapshot.data;

        if (downloads == null) {
          return SizedBox(
            width: 48,
            height: 48,
            child: IconButton(
              tooltip: snapshot.hasError ? 'お気に入りを準備できませんでした' : 'お気に入りを準備中',
              onPressed: null,
              icon: Icon(
                snapshot.hasError ? Icons.error_outline : Icons.star_border,
              ),
            ),
          );
        }

        return FavoriteWorkButton(
          library: UserLibraryStore.forRoot(downloads.store.root),
          sourceId: record.sourceId,
          tab: record.tab,
          work: record.work,
        );
      },
    );
  }
}

Future<void> openRuleLibraryItem({
  required BuildContext context,
  required DownloadStore store,
  required LibraryItem item,
  required bool history,
}) async {
  final siteId = ruleLibrarySiteId(item.sourceId);
  final selected = history ? item.chapter : null;

  if (selected != null) {
    validateRuleLibraryChapter(selected);

    if (selected.workId != item.work.id || selected.sourceId != item.sourceId) {
      throw const FormatException('作品と履歴が一致しません');
    }
  }

  SavedSiteRule? site;

  for (final candidate in await SiteRuleStore(store.root).load()) {
    if (candidate.id == siteId) {
      site = candidate;
      break;
    }
  }

  if (!context.mounted) return;

  final thumbnail = item.work.thumbnail == null
      ? null
      : htmlProbeUri(item.work.thumbnail!);

  final browseItem = RuleBrowseItem(
    title: item.work.title,
    url: htmlProbeUri(item.work.url.toString()),
    thumbnail: thumbnail,
    date: '',
    latestChapter: '',
    issues: const [],
  );

  final resumeItem = selected == null
      ? null
      : RuleBrowseItem(
          title: selected.title,
          url: selected.url,
          thumbnail: thumbnail,
          date: selected.publishedDateText ?? '',
          latestChapter: '',
          issues: const [],
        );

  if (site != null) {
    final currentSite = site;

    final record = ruleLibraryWork(
      site: currentSite,
      workUrl: browseItem.url.toString(),
      title: item.work.title,
      thumbnail: thumbnail,
    );

    if (selected != null) {
      switch (ruleLibraryHistoryDestination(currentSite)) {
        case RuleLibraryHistoryDestination.chapters:
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => RuleBrowsePage(
                site: currentSite,
                kind: 'chapters',
                targetUrl: record.work.id,
                workTitle: record.work.title,
                workThumbnail: thumbnail,
                resumeChapter: resumeItem,
              ),
            ),
          );
          return;

        case RuleLibraryHistoryDestination.details:
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => ChapterlessDetailsPage(
                site: currentSite,
                item: browseItem,
                resumeChapter: resumeItem,
              ),
            ),
          );
          return;

        case RuleLibraryHistoryDestination.reader:
          break;
      }
    }

    if (selected == null) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => switch (currentSite.readingMode) {
            SiteReadingMode.chapters => RuleBrowsePage(
              site: currentSite,
              kind: 'chapters',
              targetUrl: record.work.id,
              workTitle: record.work.title,
              workThumbnail: thumbnail,
            ),
            SiteReadingMode.direct => ChapterlessReaderPage(
              site: currentSite,
              item: browseItem,
              workUrl: record.work.url,
            ),
            SiteReadingMode.details => ChapterlessDetailsPage(
              site: currentSite,
              item: browseItem,
            ),
          },
        ),
      );
      return;
    }
  }

  // 直接読む方式、またはサイト設定が削除済みの場合。
  // 保存画像があれば、ネットワーク取得なしで本文を開く。
  if (selected != null && (site == null || !usesRuleVideo(site))) {
    final local = await store.load(selected);

    if (!context.mounted) return;

    if (local.isNotEmpty) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ChapterReaderPage(
            adapter: RuleLibraryOfflineAdapter(item.sourceId),
            store: store,
            chapters: [selected],
            initialIndex: 0,
            offlineOnly: true,
            onChapterOpened: (opened) => UserLibraryStore.forRoot(
              store.root,
            ).remember(item.sourceId, item.tab, item.work, opened),
          ),
        ),
      );
      return;
    }
  }

  if (site == null) {
    throw StateError(
      'このサイト設定は削除されています。'
      '保存画像がある作品は「保存済み」から開けます。',
    );
  }

  if (selected == null) {
    throw const FormatException('再開する履歴がありません');
  }

  final currentSite = site;

  final record = ruleLibraryWork(
    site: currentSite,
    workUrl: item.work.id,
    title: item.work.title,
    thumbnail: thumbnail,
  );

  final chapters = await ruleLibraryNavigation(
    store: store,
    record: record,
    selected: selected,
  );

  if (!context.mounted) return;

  final index = chapters.indexWhere(
    (chapter) => chapter.url.toString() == selected.url.toString(),
  );

  if (index < 0) {
    throw const FormatException('履歴の話が見つかりません');
  }

  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => RuleOnlineReaderPage(
        site: currentSite,
        chapters: chapters,
        initialIndex: index,
        workUrl: record.work.id,
        workTitle: record.work.title,
        workThumbnail: thumbnail,
      ),
    ),
  );
}
