import 'dart:convert';

import 'html_probe.dart';
import 'list_extraction_rule.dart';
import 'video_source.dart';

enum SiteReadingMode { chapters, direct, details }

extension SiteReadingModeLabel on SiteReadingMode {
  String get label => switch (this) {
    SiteReadingMode.chapters => 'チャプター一覧を開く',
    SiteReadingMode.direct => '直接読む',
    SiteReadingMode.details => '作品詳細を表示してから読む',
  };
}

/// サイトの開き方と、チャプターなし詳細画面の設定。
///
/// 個人の閲覧位置や履歴は含めない。
/// 未設定の既存サイトはチャプター方式として扱う。
class SiteReadingSettings {
  const SiteReadingSettings({
    this.mode = SiteReadingMode.chapters,
    this.detailsRule,
    this.readLink,
    this.video,
  });

  final SiteReadingMode mode;

  /// チャプター一覧とは独立した作品詳細ルール。
  ///
  /// 既存の作品詳細編集・抽出機能を使うため、
  /// ListExtractionRuleのdetailsにタイトル等を保持する。
  /// groupSelectorはhtml、kindはworksとして扱う。
  final ListExtractionRule? detailsRule;

  /// nullなら、詳細ページ自体を本文画像の取得先にする。
  /// 設定があれば、詳細ページから「読む」リンクを抽出する。
  final ListFieldRule? readLink;
  final VideoSourceSettings? video;

  SiteReadingSettings withVideo(VideoSourceSettings? value) =>
      SiteReadingSettings(
        mode: mode,
        detailsRule: detailsRule,
        readLink: readLink,
        video: value,
      );

  void validate() {
    video?.validate();
    final rule = detailsRule;
    final link = readLink;

    if (mode == SiteReadingMode.details && rule == null) {
      throw const FormatException('詳細方式には作品詳細ルールが必要です');
    }

    if (rule != null) {
      rule.validate();

      if (rule.kind != 'works' ||
          rule.groupSelector != 'html' ||
          rule.paginationUrl.isNotEmpty ||
          rule.details.containsKey('chapterNumber')) {
        throw const FormatException(
          'チャプターなし詳細はhtml全体を対象にし、'
          'ページ送り・話数設定は含めません',
        );
      }
    }

    if (link != null) {
      if (rule == null ||
          !link.enabled ||
          link.selector.trim().isEmpty ||
          link.mode == ListValueMode.cssUrl ||
          link.localizeRelativeTime) {
        throw const FormatException('読むリンクの設定が不正です');
      }

      // 属性名・セレクター長・正規表現等は既存の検証を再利用する。
      final fields = defaultListFields();
      fields['url'] = link;

      ListExtractionRule(
        pageUrl: rule.pageUrl,
        groupSelector: 'html',
        fields: fields,
      ).validate();
    }

    if (utf8.encode(jsonEncode(toJson())).length > 96 * 1024) {
      throw const FormatException('開き方の設定が大きすぎます');
    }
  }

  void validateFor(Iterable<ListExtractionRule> rules) {
    validate();
    video?.validateFor(rules.map((rule) => rule.pageUrl));

    final detail = detailsRule;
    if (detail == null) return;

    final origin = htmlProbeUri(detail.pageUrl).origin;

    for (final rule in rules) {
      if (htmlProbeUri(rule.pageUrl).origin != origin) {
        throw const FormatException('作品詳細のサンプルURLと一覧ルールの取得元が異なります');
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'version': video == null ? 1 : 2,
    'mode': mode.name,
    if (video != null) 'video': video!.toJson(),
    if (detailsRule != null) 'detailsRule': detailsRule!.toJson(),
    if (readLink != null) 'readLink': readLink!.toJson(),
  };

  factory SiteReadingSettings.fromJson(Map<String, dynamic> data) {
    if ((data['version'] != 1 && data['version'] != 2) ||
        data['mode'] is! String ||
        data.keys.any(
          (key) => !const {
            'version',
            'mode',
            'detailsRule',
            'readLink',
            'video',
          }.contains(key),
        )) {
      throw const FormatException('未対応の開き方設定です');
    }

    if (data['video'] != null &&
        (data['version'] != 2 || data['video'] is! Map)) {
      throw const FormatException('動画設定には開き方設定バージョン2が必要です');
    }

    final matching = SiteReadingMode.values.where(
      (mode) => mode.name == data['mode'],
    );

    if (matching.length != 1 ||
        (data['detailsRule'] != null && data['detailsRule'] is! Map) ||
        (data['readLink'] != null && data['readLink'] is! Map)) {
      throw const FormatException('開き方設定の値が不正です');
    }

    final settings = SiteReadingSettings(
      mode: matching.single,
      video: data['video'] == null
          ? null
          : VideoSourceSettings.fromJson(
              Map<String, dynamic>.from(data['video'] as Map),
            ),
      detailsRule: data['detailsRule'] == null
          ? null
          : ListExtractionRule.parse(jsonEncode(data['detailsRule'])),
      readLink: data['readLink'] == null
          ? null
          : ListFieldRule.fromJson(
              Map<String, dynamic>.from(data['readLink'] as Map),
            ),
    );

    settings.validate();
    return settings;
  }
}
