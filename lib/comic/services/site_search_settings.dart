import 'dart:convert';

import 'html_probe.dart';
import 'list_extraction_rule.dart';
import 'page_url_template.dart';

String normalizeSiteSearchKeyword(String input, {bool normalizeSpaces = true}) {
  if (input.length > 256) {
    throw const FormatException('検索語は256文字以内で入力してください');
  }

  final value = normalizeSpaces
      ? input.replaceAll(RegExp(r'[\s\u3000]+'), ' ').trim()
      : input.trim();

  if (value.isEmpty) {
    throw const FormatException('検索語を入力してください');
  }

  return value;
}

class SiteSearchUrlTemplate {
  SiteSearchUrlTemplate(
    String input, {
    this.spaceEncoding = 'plus',
    this.normalizeSpaces = true,
  }) : template = input.trim() {
    _validate();
  }

  static const keywordMarker = '{keyword}';

  final String template;
  final String spaceEncoding;
  final bool normalizeSpaces;

  RegExpMatch? get _pageMatch => RegExp(r'\{page;(\d+)\}').firstMatch(template);

  bool get hasPagination => _pageMatch != null;

  bool get _keywordInQuery {
    final query = template.indexOf('?');
    return query >= 0 && template.indexOf(keywordMarker) > query;
  }

  void _checkPosition(String marker) {
    final origin = RegExp(r'^https://[^/?#]+').firstMatch(template);
    final position = template.indexOf(marker);

    if (origin == null || position < origin.end) {
      throw const FormatException('検索語とページ番号はURLのパスまたはクエリに指定してください');
    }

    final query = template.indexOf('?');

    if (query >= 0 && position > query) {
      final component = template
          .substring(query + 1)
          .split('&')
          .firstWhere((part) => part.contains(marker));
      final equals = component.indexOf('=');

      if (equals <= 0 || component.indexOf(marker) <= equals) {
        throw const FormatException('検索語とページ番号はクエリの項目名ではなく値に指定してください');
      }
    }
  }

  void _validate() {
    if (template.isEmpty ||
        template.length > 4096 ||
        RegExp(r'\s').hasMatch(template)) {
      throw const FormatException('検索URLは空白を含まない4096文字以内のURLで指定してください');
    }

    if (!const ['plus', 'percent'].contains(spaceEncoding)) {
      throw const FormatException('検索語のスペース送信方式が不正です');
    }

    if (RegExp(RegExp.escape(keywordMarker)).allMatches(template).length != 1) {
      throw const FormatException('検索URLには {keyword} を1個指定してください');
    }

    final pages = RegExp(
      r'\{page;(\d+)\}',
    ).allMatches(template).toList(growable: false);

    if (pages.length > 1) {
      throw const FormatException('ページ番号は1個まで指定できます');
    }

    final remaining = template
        .replaceAll(keywordMarker, '')
        .replaceAll(RegExp(r'\{page;\d+\}'), '');

    if (remaining.contains('{') || remaining.contains('}')) {
      throw const FormatException('未対応のURLプレースホルダーがあります');
    }

    _checkPosition(keywordMarker);

    if (pages.isNotEmpty) {
      _checkPosition(pages.single.group(0)!);
    }

    final sampleTemplate = template.replaceAll(keywordMarker, 'sample');
    final sample = pages.isEmpty
        ? sampleTemplate
        : PageUrlTemplate(
            sampleTemplate,
          ).url(PageUrlTemplate(sampleTemplate).start);

    final parsed = Uri.parse(sample);

    if (parsed.hasFragment) {
      throw const FormatException('検索URLにフラグメントは指定できません');
    }

    htmlProbeUri(sample);
  }

  String _withKeyword(String input) {
    final keyword = normalizeSiteSearchKeyword(
      input,
      normalizeSpaces: normalizeSpaces,
    );

    if (!_keywordInQuery && (keyword == '.' || keyword == '..')) {
      throw const FormatException('パス型の検索URLでは、この検索語は使用できません');
    }

    // URL全体ではなく、検索語だけを1回エンコードする。
    // +として送るのはスペースだけ。文字としての+は%2Bになる。
    final encoded = _keywordInQuery && spaceEncoding == 'plus'
        ? Uri.encodeQueryComponent(keyword)
        : Uri.encodeComponent(keyword);

    final value = template.replaceAll(keywordMarker, encoded);

    if (value.length > 4096) {
      throw const FormatException('生成された検索URLが長すぎます');
    }

    return value;
  }

  String url(String keyword, {int? page}) {
    final value = _withKeyword(keyword);

    if (!hasPagination) {
      if (page != null) {
        throw const FormatException('この検索設定にはページ送りがありません');
      }
      return htmlProbeUri(value).toString();
    }

    final pagination = PageUrlTemplate(value);
    return pagination.url(page ?? pagination.start);
  }

  String paginationUrl(String keyword) {
    final value = _withKeyword(keyword);

    if (!hasPagination) return '';

    PageUrlTemplate(value);
    return value;
  }
}

class SiteSearchSettings {
  const SiteSearchSettings({
    required this.urlTemplate,
    this.spaceEncoding = 'plus',
    this.normalizeSpaces = true,
    this.rule,
  });

  final String urlTemplate;
  final String spaceEncoding;
  final bool normalizeSpaces;

  /// nullなら通常の作品一覧の抽出設定を使う。
  final ListExtractionRule? rule;

  SiteSearchUrlTemplate get template => SiteSearchUrlTemplate(
    urlTemplate,
    spaceEncoding: spaceEncoding,
    normalizeSpaces: normalizeSpaces,
  );

  void validate() {
    template;

    final custom = rule;
    if (custom == null) return;

    custom.validate();

    if (custom.kind != 'works') {
      throw const FormatException('検索結果には作品一覧ルールを設定してください');
    }

    if (custom.paginationUrl.isNotEmpty) {
      throw const FormatException(
        '検索のページ送りは検索URLの {page;1} で設定してください。'
        '検索結果ルール内のページ送りURLは空欄にしてください',
      );
    }
  }

  void validateFor(Map<String, ListExtractionRule> sourceRules) {
    validate();

    final works = sourceRules['works'];
    if (works == null) {
      throw const FormatException('先に通常の作品一覧を設定してください');
    }

    final origin = htmlProbeUri(works.pageUrl).origin;

    if (htmlProbeUri(template.url('sample')).origin != origin ||
        (rule != null && htmlProbeUri(rule!.pageUrl).origin != origin)) {
      throw const FormatException('検索URLと検索結果ルールは作品一覧と同じ取得元にしてください');
    }
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'urlTemplate': urlTemplate,
    'spaceEncoding': spaceEncoding,
    'normalizeSpaces': normalizeSpaces,
    if (rule != null) 'rule': rule!.toJson(),
  };

  factory SiteSearchSettings.fromJson(Map<String, dynamic> data) {
    if (data['version'] != 1 ||
        data.keys.any(
          (key) => !const {
            'version',
            'urlTemplate',
            'spaceEncoding',
            'normalizeSpaces',
            'rule',
          }.contains(key),
        ) ||
        data['urlTemplate'] is! String ||
        data['spaceEncoding'] is! String ||
        data['normalizeSpaces'] is! bool ||
        (data.containsKey('rule') && data['rule'] is! Map)) {
      throw const FormatException('検索設定の形式が不正です');
    }

    final result = SiteSearchSettings(
      urlTemplate: data['urlTemplate'] as String,
      spaceEncoding: data['spaceEncoding'] as String,
      normalizeSpaces: data['normalizeSpaces'] as bool,
      rule: data['rule'] == null
          ? null
          : ListExtractionRule.parse(jsonEncode(data['rule'])),
    );

    result.validate();
    return result;
  }
}
