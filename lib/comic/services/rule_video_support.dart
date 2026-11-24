import 'site_rule_store.dart';

bool usesRuleVideo(SavedSiteRule site) => site.readingSettings?.video != null;

bool canOpenRuleContent(SavedSiteRule site) =>
    usesRuleVideo(site) || site.images != null;

void requireRuleImageDownload(SavedSiteRule site) {
  if (usesRuleVideo(site)) {
    throw UnsupportedError('このサイトは動画再生を使用しています。動画の保存にはまだ対応していません。');
  }
}
