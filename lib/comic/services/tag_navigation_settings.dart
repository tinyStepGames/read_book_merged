import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'html_probe.dart';
import 'list_extraction_rule.dart';
import 'list_text_transform.dart';

class TagNavigationSettings {
  const TagNavigationSettings({
    required this.rule,
    this.urlPattern = '',
    this.urlReplacement = '',
  });

  final ListExtractionRule rule;
  final String urlPattern;
  final String urlReplacement;

  void validate() {
    rule.validate();

    if (rule.kind != 'works') {
      throw const FormatException('タグ先には作品一覧ルールを設定してください');
    }

    validateListTransform(urlPattern, urlReplacement);

    if (urlPattern.isEmpty && urlReplacement.isNotEmpty) {
      throw const FormatException('URLの整形テンプレートを使う場合は正規表現も指定してください');
    }
  }

  void validateFor(Iterable<ListExtractionRule> sourceRules) {
    validate();

    final rules = sourceRules.toList(growable: false);
    if (rules.isEmpty) {
      throw const FormatException('先にサイトの一覧ルールを設定してください');
    }

    final works = rules.where((value) => value.kind == 'works');
    final reference = works.isEmpty ? rules.first : works.first;

    if (htmlProbeUri(reference.pageUrl).origin !=
        htmlProbeUri(rule.pageUrl).origin) {
      throw const FormatException('タグ先の設定は作品一覧と同じ取得元にしてください');
    }
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'rule': rule.toJson(),
    'urlPattern': urlPattern,
    'urlReplacement': urlReplacement,
  };

  factory TagNavigationSettings.fromJson(Map<String, dynamic> data) {
    if (data['version'] != 1 ||
        data.keys.any(
          (key) => !const {
            'version',
            'rule',
            'urlPattern',
            'urlReplacement',
          }.contains(key),
        ) ||
        data['rule'] is! Map ||
        data['urlPattern'] is! String ||
        data['urlReplacement'] is! String) {
      throw const FormatException('タグ先の設定形式が不正です');
    }

    final value = TagNavigationSettings(
      rule: ListExtractionRule.parse(jsonEncode(data['rule'])),
      urlPattern: data['urlPattern'] as String,
      urlReplacement: data['urlReplacement'] as String,
    );

    value.validate();
    return value;
  }
}

/// 正規表現・整形テンプレートが空なら、元のタグURLを使う。
/// 変換後も同じ取得元であることを必ず検証する。
Uri tagNavigationTargetUri(
  Uri input, {
  required String allowedOrigin,
  String pattern = '',
  String replacement = '',
}) {
  validateListTransform(pattern, replacement);

  if (pattern.isEmpty && replacement.isNotEmpty) {
    throw const FormatException('URL変換の正規表現が空です');
  }

  final source = htmlProbeUri(input.toString());

  if (source.origin != allowedOrigin) {
    throw const FormatException('タグURLの取得元が異なります');
  }

  final output = pattern.isEmpty
      ? source.toString()
      : transformListText(
          source.toString(),
          pattern: pattern,
          replacement: replacement,
        );

  final target = htmlProbeUri(output);

  if (target.origin != allowedOrigin) {
    throw const FormatException('タグURLの変換後に別の取得元へ移動することはできません');
  }

  return target.removeFragment();
}

/// URL変換の正規表現を別Isolateで実行し、時間超過時は停止する。
Future<Uri> resolveTagNavigationUrl({
  required Uri input,
  required String allowedOrigin,
  String pattern = '',
  String replacement = '',
}) async {
  final port = ReceivePort();
  Isolate? worker;

  try {
    worker = await Isolate.spawn<List<Object?>>(
      _tagNavigationUrlWorker,
      <Object?>[
        port.sendPort,
        input.toString(),
        allowedOrigin,
        pattern,
        replacement,
      ],
      onError: port.sendPort,
      onExit: port.sendPort,
      errorsAreFatal: true,
    );

    final message = await port.first.timeout(
      const Duration(seconds: 3),
      onTimeout: () =>
          throw const FormatException('タグURLの変換が時間上限を超えました。正規表現を簡単にしてください'),
    );

    if (message is List &&
        message.length == 2 &&
        message[0] == 'ok' &&
        message[1] is String) {
      return htmlProbeUri(message[1] as String);
    }

    if (message is List && message.length == 2 && message[0] == 'error') {
      throw FormatException(message[1].toString());
    }

    throw const FormatException('タグURLの変換処理が終了しました');
  } finally {
    worker?.kill(priority: Isolate.immediate);
    port.close();
  }
}

void _tagNavigationUrlWorker(List<Object?> input) {
  final port = input[0] as SendPort;

  try {
    final target = tagNavigationTargetUri(
      htmlProbeUri(input[1] as String),
      allowedOrigin: input[2] as String,
      pattern: input[3] as String,
      replacement: input[4] as String,
    );

    port.send(<Object?>['ok', target.toString()]);
  } catch (error) {
    port.send(<Object?>['error', error.toString()]);
  }
}
