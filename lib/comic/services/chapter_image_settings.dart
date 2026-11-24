import 'dart:convert';

import 'chapter_image_rule.dart';
import 'html_probe.dart';

class ChapterImageSettings {
  const ChapterImageSettings({
    required this.pageUrl,
    required this.acquisition,
    required this.rule,
  });

  /// 設定テスト用。読むときは選択チャプターのURLを使う。
  final String pageUrl;
  final String acquisition;
  final ChapterImageRule rule;

  void validate() {
    if (pageUrl.length > 4096) {
      throw const FormatException('チャプターのサンプルURLが長すぎます');
    }
    htmlProbeUri(pageUrl);
    if (!const {'staticHtml', 'renderedDom'}.contains(acquisition)) {
      throw const FormatException('本文画像の取得方式が未対応です');
    }
    rule.validate();
  }

  void validateOrigins(Iterable<String> listUrls) {
    validate();
    final origin = htmlProbeUri(pageUrl).origin;
    for (final url in listUrls) {
      if (htmlProbeUri(url).origin != origin) {
        throw const FormatException(
          '本文画像のサンプルURLと一覧ルールの取得元が異なります。'
          '別サイトへの誤保存がないか確認してください',
        );
      }
    }
  }

  Map<String, Object?> toJson() => {
    'type': 'chapterImageSettings',
    'version': 1,
    'pageUrl': pageUrl,
    'acquisition': acquisition,
    'rule': rule.toJson(),
  };

  String encodeJson() {
    validate();
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  factory ChapterImageSettings.parse(String input) {
    if (utf8.encode(input).length > 65536) {
      throw const FormatException('本文画像の保存設定が大きすぎます');
    }

    final Object? value;
    try {
      value = jsonDecode(input);
    } catch (_) {
      throw const FormatException('本文画像の保存設定JSONが不正です');
    }

    if (value is! Map ||
        value.keys.any(
          (key) => !const {
            'type',
            'version',
            'pageUrl',
            'acquisition',
            'rule',
          }.contains(key),
        ) ||
        value['type'] != 'chapterImageSettings' ||
        value['version'] != 1 ||
        value['pageUrl'] is! String ||
        value['acquisition'] is! String ||
        value['rule'] is! Map) {
      throw const FormatException('本文画像の保存設定形式が不正です');
    }

    final settings = ChapterImageSettings(
      pageUrl: value['pageUrl'] as String,
      acquisition: value['acquisition'] as String,
      rule: ChapterImageRule.parse(jsonEncode(value['rule'])),
    );
    settings.validate();
    return settings;
  }
}
