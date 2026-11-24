import 'dart:convert';
import 'dart:math';

import 'html_probe.dart';
import 'list_extraction_rule.dart';
import 'page_url_template.dart';

String newSiteBrowseTabId() {
  final random = Random.secure();
  return 'tab_${DateTime.now().microsecondsSinceEpoch}_'
      '${random.nextInt(1 << 30)}';
}

class SiteBrowseTab {
  const SiteBrowseTab({
    required this.id,
    required this.title,
    required this.pageUrl,
    this.paginationUrl = '',
    this.ruleSource = 'works',
    this.customRule,
  });

  static const maxTabs = 12;

  final String id;
  final String title;
  final String pageUrl;
  final String paginationUrl;

  /// works / tags / custom
  final String ruleSource;

  final ListExtractionRule? customRule;

  void validate() {
    if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
      throw const FormatException('タブIDが不正です');
    }

    if (title.trim().isEmpty || title.length > 40) {
      throw const FormatException('タブ名は1～40文字で入力してください');
    }

    if (pageUrl.length > 4096) {
      throw const FormatException('タブURLが長すぎます');
    }

    final parsed = Uri.parse(pageUrl.trim());
    if (parsed.hasFragment) {
      throw const FormatException('タブURLにフラグメントは指定できません');
    }

    htmlProbeUri(pageUrl);

    if (!const ['works', 'tags', 'custom'].contains(ruleSource)) {
      throw const FormatException('タブの抽出ルール指定が不正です');
    }

    if (paginationUrl.isNotEmpty) {
      PageUrlTemplate(paginationUrl).validateOrigin(pageUrl);
    }

    if (ruleSource == 'custom' && customRule == null) {
      throw const FormatException('専用の一覧ルールを設定してください');
    }

    final custom = customRule;
    if (custom != null) {
      custom.validate();

      if (custom.kind != 'works') {
        throw const FormatException('タブには作品一覧ルールを設定してください');
      }

      if (htmlProbeUri(custom.pageUrl).origin != htmlProbeUri(pageUrl).origin) {
        throw const FormatException('タブURLと専用ルールの取得元が異なります');
      }
    }
  }

  void validateFor(Map<String, ListExtractionRule> rules) {
    validate();

    final works = rules['works'];
    if (works == null) {
      throw const FormatException('先に通常の作品一覧を設定してください');
    }

    if (htmlProbeUri(works.pageUrl).origin != htmlProbeUri(pageUrl).origin) {
      throw const FormatException('タブURLは通常の作品一覧と同じ取得元にしてください');
    }
  }

  static void validateList(
    List<SiteBrowseTab> tabs,
    Map<String, ListExtractionRule> rules,
  ) {
    if (tabs.length > maxTabs) {
      throw const FormatException('追加できるタブは12個までです');
    }

    if (tabs.map((tab) => tab.id).toSet().length != tabs.length) {
      throw const FormatException('タブIDが重複しています');
    }

    for (final tab in tabs) {
      tab.validateFor(rules);
    }
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'title': title,
    'pageUrl': pageUrl,
    'paginationUrl': paginationUrl,
    'ruleSource': ruleSource,
    if (customRule != null) 'customRule': customRule!.toJson(),
  };

  factory SiteBrowseTab.fromJson(Map<String, dynamic> data) {
    if (data['version'] != 1 ||
        data.keys.any(
          (key) => !const {
            'version',
            'id',
            'title',
            'pageUrl',
            'paginationUrl',
            'ruleSource',
            'customRule',
          }.contains(key),
        ) ||
        data['id'] is! String ||
        data['title'] is! String ||
        data['pageUrl'] is! String ||
        data['paginationUrl'] is! String ||
        data['ruleSource'] is! String ||
        (data.containsKey('customRule') && data['customRule'] is! Map)) {
      throw const FormatException('タブの保存形式が不正です');
    }

    final result = SiteBrowseTab(
      id: data['id'] as String,
      title: data['title'] as String,
      pageUrl: data['pageUrl'] as String,
      paginationUrl: data['paginationUrl'] as String,
      ruleSource: data['ruleSource'] as String,
      customRule: data['customRule'] == null
          ? null
          : ListExtractionRule.parse(jsonEncode(data['customRule'])),
    );

    result.validate();
    return result;
  }

  static List<SiteBrowseTab> parseList(dynamic value) {
    if (value == null) return const [];

    if (value is! List || value.length > maxTabs) {
      throw const FormatException('タブ一覧の保存形式が不正です');
    }

    final result = <SiteBrowseTab>[];

    for (final item in value) {
      if (item is! Map) {
        throw const FormatException('タブ設定はオブジェクト形式です');
      }

      result.add(SiteBrowseTab.fromJson(Map<String, dynamic>.from(item)));
    }

    return List<SiteBrowseTab>.unmodifiable(result);
  }
}
