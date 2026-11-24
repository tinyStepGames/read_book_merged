import 'html_probe.dart';

/// 例: https://example.com/list?page={page;1}
/// プレースホルダーはURLのパス・クエリ部分に1個だけ使用できる。
class PageUrlTemplate {
  PageUrlTemplate(String input) : template = input.trim() {
    if (template.length > 4096) {
      throw const FormatException('ページ送りURLが長すぎます');
    }

    final matches = _marker.allMatches(template).toList();
    if (matches.length != 1) {
      throw const FormatException('ページ送りURLには {page;1} の形式を1個指定してください');
    }

    _match = matches.single;
    final parsed = int.tryParse(_match.group(1)!);

    if (parsed == null || parsed < 0 || parsed > maxPage) {
      throw const FormatException('開始ページは0～999999で指定してください');
    }

    start = parsed;

    final withoutMarker = template.replaceRange(_match.start, _match.end, '');
    if (withoutMarker.contains('{') || withoutMarker.contains('}')) {
      throw const FormatException('未対応のURLプレースホルダーがあります');
    }

    // スキーム・ホスト・認証情報の一部には使用させない。
    final originMatch = RegExp(r'^https://[^/?#]+').firstMatch(template);
    if (originMatch == null || _match.start < originMatch.end) {
      throw const FormatException('ページ番号はURLのパスまたはクエリに指定してください');
    }

    final first = Uri.parse(url(start));
    final second = Uri.parse(url(start == maxPage ? start - 1 : start + 1));

    if (first.hasFragment || first.origin != second.origin) {
      throw const FormatException('ページ送りURLの取得元・フラグメントを確認してください');
    }
  }

  static final _marker = RegExp(r'\{page;(\d+)\}');
  static const maxPage = 999999;

  final String template;
  late final RegExpMatch _match;
  late final int start;

  String url(int page) {
    if (page < 0 || page > maxPage) {
      throw const FormatException('ページ番号が上限を超えました');
    }

    final value = template.replaceRange(
      _match.start,
      _match.end,
      page.toString(),
    );

    // 認証情報なし・HTTPSの検証。フラグメントは呼び出し元で拒否。
    htmlProbeUri(value);
    return value;
  }

  void validateOrigin(String sampleUrl) {
    if (htmlProbeUri(url(start)).origin != htmlProbeUri(sampleUrl).origin) {
      throw const FormatException('対象URLとページ送りURLの取得元が異なります');
    }
  }
}
