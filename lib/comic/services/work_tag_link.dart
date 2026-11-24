import 'package:html/dom.dart';

import 'html_probe.dart';

class WorkTagLink {
  const WorkTagLink({required this.label, required this.url});

  final String label;
  final Uri url;
}

/// タグの表示要素に対応するリンクを取得する。
/// 複数リンクから勝手に先頭を選ぶことはしない。
WorkTagLink? workTagLinkForElement({
  required Element element,
  required String label,
  required Uri pageUri,
  required Uri baseUri,
}) {
  if (label.trim().isEmpty) return null;

  Element? anchor;

  if (element.localName == 'a' && element.attributes.containsKey('href')) {
    anchor = element;
  } else {
    var parent = element.parent;

    while (parent != null) {
      if (parent.localName == 'a' && parent.attributes.containsKey('href')) {
        anchor = parent;
        break;
      }

      parent = parent.parent;
    }

    if (anchor == null) {
      final children = element.querySelectorAll('a[href]');

      if (children.length > 1) {
        throw const FormatException(
          '1つのタグに複数のリンクがあります。'
          'セレクターを1タグずつのa要素に合わせてください',
        );
      }

      if (children.length == 1) {
        anchor = children.single;
      }
    }
  }

  if (anchor == null) return null;

  final href = anchor.attributes['href']?.trim() ?? '';

  // ページ内ジャンプやリンクなしは、表示専用タグとして残す。
  if (href.isEmpty || href.startsWith('#')) return null;

  if (href.length > 4096) {
    throw const FormatException('タグURLが長すぎます');
  }

  final resolved = htmlProbeUri(baseUri.resolve(href).toString());

  if (resolved.origin != pageUri.origin) {
    throw const FormatException('別の取得元のタグリンクは使用できません');
  }

  return WorkTagLink(label: label.trim(), url: resolved.removeFragment());
}
