import 'dart:convert';

import 'package:html/parser.dart' as html;

import 'html_probe.dart';

/// 本文画像専用の抽出設定。
/// サンプルページURLや作品固有のIDは保持しない。
class ChapterImageRule {
  const ChapterImageRule({required this.selector, this.attribute = 'src'});

  final String selector;
  final String attribute;

  void validate() {
    if (selector.trim().isEmpty || selector.length > 8192) {
      throw const FormatException('本文画像のCSSセレクターは1～8192文字で指定してください');
    }

    final name = attribute.trim();

    if (!RegExp(r'^[A-Za-z_:][A-Za-z0-9_.:-]{0,99}$').hasMatch(name)) {
      throw const FormatException('画像URLの属性名が不正です');
    }

    if (const {'srcset', 'data-srcset', 'style'}.contains(name.toLowerCase())) {
      throw const FormatException(
        'srcset・styleの解析は未対応です。'
        '1つの画像URLが入っている属性を指定してください',
      );
    }
  }

  Map<String, Object?> toJson() => {
    'type': 'chapterImages',
    'version': 1,
    'selector': selector,
    'attribute': attribute,
  };

  String encodeJson() {
    validate();
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  factory ChapterImageRule.parse(String input) {
    if (utf8.encode(input).length > 32768) {
      throw const FormatException('本文画像ルールが大きすぎます');
    }

    final Object? value;
    try {
      value = jsonDecode(input);
    } catch (_) {
      throw const FormatException('本文画像ルールのJSONが不正です');
    }

    if (value is! Map ||
        value.keys.any(
          (key) =>
              !const {'type', 'version', 'selector', 'attribute'}.contains(key),
        ) ||
        value['type'] != 'chapterImages' ||
        value['version'] != 1 ||
        value['selector'] is! String ||
        value['attribute'] is! String) {
      throw const FormatException('本文画像ルールの形式が不正です');
    }

    final rule = ChapterImageRule(
      selector: value['selector'] as String,
      attribute: value['attribute'] as String,
    );
    rule.validate();
    return rule;
  }
}

class ChapterImageReport {
  const ChapterImageReport({
    required this.matchedCount,
    required this.images,
    required this.duplicateCount,
    required this.issues,
  });

  final int matchedCount;

  /// HTML順。クエリ文字列は保持し、完全に同じURLだけを重複排除する。
  final List<Uri> images;

  final int duplicateCount;

  /// 空属性・不正URLなど。1つでもあれば自動的に閲覧へ進めない。
  final List<String> issues;

  bool get isUsable => images.isNotEmpty && issues.isEmpty;
}

Uri _checkedImageUri(Uri base, String input) {
  if (input.isEmpty) {
    throw const FormatException('画像URLの属性が空です');
  }

  if (input.length > 8192 ||
      RegExp(r'[\s\u0000-\u001f\u007f\\]').hasMatch(input)) {
    throw const FormatException('画像URLが長すぎるか、空白・制御文字・バックスラッシュを含んでいます');
  }

  final Uri uri;
  try {
    uri = base.resolve(input);
  } catch (_) {
    throw const FormatException('画像URLを解析できません');
  }

  if (uri.scheme != 'https' || uri.host.isEmpty || uri.userInfo.isNotEmpty) {
    throw const FormatException('画像URLは認証情報を含まないHTTPSに限定しています');
  }

  // クエリ・エンコードされた文字は保持する。
  return uri.removeFragment();
}

/// 取得済みHTMLだけを解析する純粋な処理。
/// 通信・画像保存・履歴保存は行わない。
///
/// 後で画面へ接続する際には、Isolateと時間制限を付けて呼び出す。
ChapterImageReport extractChapterImages({
  required HtmlProbePage page,
  required ChapterImageRule rule,
}) {
  rule.validate();

  if (page.source.length > HtmlProbeClient.maxBytes ||
      utf8.encode(page.source).length > HtmlProbeClient.maxBytes) {
    throw const FormatException('解析するHTMLが上限の2MiBを超えています');
  }

  var base = htmlProbeUri(page.uri.toString());
  final document = html.parse(page.source);

  // HTMLの最初のbase[href]があれば、ブラウザーと同様に解決基準にする。
  final baseElement = document.querySelector('base[href]');
  if (baseElement != null) {
    final rawBase = baseElement.attributes['href']!.trim();

    if (rawBase.isNotEmpty) {
      try {
        base = _checkedImageUri(base, rawBase);
      } catch (error) {
        throw FormatException('HTML内のbase URLが不正です：$error');
      }
    }
  }

  // 未対応セレクターを含め、照合エラーは呼び出し元へ返す。
  final elements = document.querySelectorAll(rule.selector.trim());

  if (elements.length > 2000) {
    throw const FormatException('画像候補が2000件を超えています。本文部分に対象を絞ってください');
  }

  final images = <Uri>[];
  final seen = <String>{};
  final issues = <String>[];
  var duplicates = 0;
  final attribute = rule.attribute.trim();

  if (elements.isEmpty) {
    issues.add('本文画像のセレクターに一致する要素がありません');
  }

  for (var index = 0; index < elements.length; index++) {
    final raw = elements[index].attributes[attribute]?.trim() ?? '';

    try {
      final uri = _checkedImageUri(base, raw);
      if (seen.add(uri.toString())) {
        images.add(uri);
      } else {
        duplicates++;
      }
    } catch (error) {
      issues.add('候補${index + 1}：$error');
    }
  }

  return ChapterImageReport(
    matchedCount: elements.length,
    images: List.unmodifiable(images),
    duplicateCount: duplicates,
    issues: List.unmodifiable(issues),
  );
}
