import 'sources/source_adapter.dart';

String chapterDateLabel(ComicChapter chapter) {
  final date = chapter.publishedDateText?.trim();
  return date == null || date.isEmpty ? '公開日：—' : '公開日：$date';
}

/// 履歴なしなら元の一覧の先頭へ。
/// 履歴の話が一覧にない場合は、勝手に別の話へ移動しない。
ComicChapter? readingEntryChapter(
  List<ComicChapter> chapters,
  String? lastChapterId,
) {
  if (chapters.isEmpty) return null;

  if (lastChapterId == null) return chapters.first;

  for (final chapter in chapters) {
    if (chapter.id == lastChapterId) return chapter;
  }

  return null;
}
