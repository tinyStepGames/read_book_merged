import 'dart:convert';

/// 元の並びを変更せず、表示用の一覧だけを作る。
/// 昇順の基準順は取得元アダプターが提供する。
List<T> chapterDisplayOrder<T>(
  Iterable<T> chapters, {
  required bool descending,
}) {
  final original = List<T>.of(chapters);

  return List<T>.unmodifiable(descending ? original.reversed : original);
}

String chapterSortCacheKey({
  required String sourceId,
  required String language,
  required String workId,
}) => 'chapter-order-v1:${jsonEncode([sourceId, language, workId])}';
