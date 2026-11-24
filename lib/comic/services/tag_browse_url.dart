/// タグURLを、サイト側の一覧形式に合わせて補正する。
///
/// Rawkuma:
///   /genre/seinen/
///     → /library/?the_genre=seinen&the_page=1
///        &orderby=updated&order=desc
///
/// 他サイトのURLは変更しない。
/// ページ送りテンプレートの適用は TagBrowsePlan 側で行う。
Uri tagBrowseTargetUri(Uri target) {
  final host = target.host.toLowerCase();

  if (host != 'rawkuma.net' && host != 'www.rawkuma.net') {
    return target;
  }

  if (target.scheme != 'https') {
    return target;
  }

  final segments = target.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);

  final isGenre =
      segments.length == 2 && segments[0] == 'genre' && segments[1].isNotEmpty;

  final isLibrary = target.path == '/library/' || target.path == '/library';

  // 未対応のパスは勝手に作品一覧へ変換しない。
  if (!isGenre && !isLibrary) {
    return target;
  }

  final query = <String, List<String>>{
    for (final entry in target.queryParametersAll.entries)
      entry.key: List<String>.of(entry.value),
  };

  if (isGenre) {
    query['the_genre'] = <String>[segments[1]];
  }

  // タグを開く際は先頭ページから表示する。
  query['the_page'] = <String>['1'];

  // 更新日時の新しい順。
  query['orderby'] = <String>['updated'];
  query['order'] = <String>['desc'];

  return target
      .replace(path: '/library/', queryParameters: query)
      .removeFragment();
}
