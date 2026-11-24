import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'html_probe.dart';
import 'list_text_transform.dart';
import 'relative_time_text.dart';
import 'page_url_template.dart';

enum ListValueMode { text, attribute, cssUrl }

const workDetailLabels = <String, String>{
  'title': '作品タイトル',
  'thumbnail': '作品の表紙',
  'description': '作品の説明',
  'tags': 'タグ',
  'chapterNumber': '並び替え用の話数',
};

const listFieldLabels = <String, String>{
  'title': 'タイトル',
  'url': 'リンク',
  'thumbnail': '表紙',
  'id': 'ID',
  'date': '公開日など',
  'latestChapter': '最新話・話数',
};

class ListFieldRule {
  const ListFieldRule({
    this.selector = '',
    this.mode = ListValueMode.text,
    this.attribute = '',
    this.enabled = true,
    this.pattern = '',
    this.replacement = '',
    this.localizeRelativeTime = false,
  });

  final String selector;
  final ListValueMode mode;
  final String attribute;
  final bool enabled;
  final String pattern;
  final String replacement;
  final bool localizeRelativeTime;

  ListFieldRule copyWith({
    String? selector,
    ListValueMode? mode,
    String? attribute,
    bool? enabled,
    String? pattern,
    String? replacement,
    bool? localizeRelativeTime,
  }) => ListFieldRule(
    selector: selector ?? this.selector,
    mode: mode ?? this.mode,
    attribute: attribute ?? this.attribute,
    enabled: enabled ?? this.enabled,
    pattern: pattern ?? this.pattern,
    replacement: replacement ?? this.replacement,
    localizeRelativeTime: localizeRelativeTime ?? this.localizeRelativeTime,
  );

  Map<String, dynamic> toJson() => {
    'selector': selector,
    'mode': mode.name,
    'attribute': attribute,
    'enabled': enabled,
    if (pattern.isNotEmpty) 'pattern': pattern,
    if (replacement.isNotEmpty) 'replacement': replacement,
    if (localizeRelativeTime) 'localizeRelativeTime': true,
  };

  factory ListFieldRule.fromJson(Map<String, dynamic> data) {
    if (data.keys.any(
      (key) => !const {
        'selector',
        'mode',
        'attribute',
        'enabled',
        'pattern',
        'replacement',
        'localizeRelativeTime',
      }.contains(key),
    )) {
      throw const FormatException('未対応の項目設定です');
    }

    if (data.containsKey('localizeRelativeTime') &&
        data['localizeRelativeTime'] is! bool) {
      throw const FormatException('相対時間の日本語化設定が不正です');
    }

    final mode = ListValueMode.values.where(
      (value) => value.name == data['mode'],
    );

    if (mode.length != 1 || data['enabled'] is! bool) {
      throw const FormatException('取得方法が不正です');
    }

    return ListFieldRule(
      selector: data['selector'] as String,
      mode: mode.single,
      attribute: data['attribute'] as String,
      enabled: data['enabled'] as bool,
      pattern: data['pattern'] as String? ?? '',
      replacement: data['replacement'] as String? ?? '',
      localizeRelativeTime: data['localizeRelativeTime'] as bool? ?? false,
    );
  }
}

Map<String, ListFieldRule> defaultListFields() => {
  'title': const ListFieldRule(),
  'url': const ListFieldRule(mode: ListValueMode.attribute, attribute: 'href'),
  'thumbnail': const ListFieldRule(
    mode: ListValueMode.attribute,
    attribute: 'src',
    enabled: false,
  ),
  'id': const ListFieldRule(
    mode: ListValueMode.attribute,
    attribute: 'id',
    enabled: false,
  ),
  'date': const ListFieldRule(enabled: false),
  'latestChapter': const ListFieldRule(enabled: false),
};

class ListExtractionRule {
  ListExtractionRule({
    required this.pageUrl,
    required this.groupSelector,
    required this.fields,
    this.kind = 'works',
    this.acquisition = 'staticHtml',
    this.details = const <String, ListFieldRule>{},
    this.paginationUrl = '',
  });

  static const qrPrefix = 'ocr-list:3:';

  final String pageUrl;
  final String groupSelector;
  final Map<String, ListFieldRule> fields;
  final String kind;
  final String acquisition;
  final Map<String, ListFieldRule> details;
  final String paginationUrl;

  void validate() {
    htmlProbeUri(pageUrl);

    if (paginationUrl.isNotEmpty) {
      if (kind != 'works') {
        throw const FormatException('ページ送りは作品一覧でのみ使用できます');
      }
      PageUrlTemplate(paginationUrl).validateOrigin(pageUrl);
    }

    if (pageUrl.length > 4096 ||
        groupSelector.length > 2048 ||
        groupSelector.trim().isEmpty) {
      throw const FormatException('まとまりのセレクターが空、または長すぎます');
    }

    if (!const ['works', 'chapters'].contains(kind) ||
        !const ['staticHtml', 'renderedDom'].contains(acquisition)) {
      throw const FormatException('一覧の種類または取得方式が不正です');
    }

    if (fields.length != listFieldLabels.length ||
        fields.keys.any((key) => !listFieldLabels.containsKey(key))) {
      throw const FormatException('項目の構成が不正です');
    }

    for (final key in ['title', 'url']) {
      if (fields[key]?.enabled != true) {
        throw const FormatException('タイトルとリンクは有効にしてください');
      }
    }

    if (details.keys.any((key) => !workDetailLabels.containsKey(key))) {
      throw const FormatException('未対応の作品詳細項目です');
    }
    for (final entry in details.entries) {
      if (entry.value.enabled && entry.value.selector.trim().isEmpty) {
        throw FormatException('${workDetailLabels[entry.key]}のセレクターが空です');
      }
    }

    for (final entry in [...fields.entries, ...details.entries]) {
      final field = entry.value;
      final label =
          listFieldLabels[entry.key] ??
          workDetailLabels[entry.key] ??
          entry.key;

      try {
        validateListTransform(field.pattern, field.replacement);
      } on FormatException catch (error) {
        throw FormatException('$label：正規表現・整形テンプレートの設定が不正です：${error.message}');
      }
      if (field.selector.length > 2048 || field.attribute.length > 128) {
        throw const FormatException('項目設定が長すぎます');
      }

      if (field.enabled &&
          field.mode != ListValueMode.text &&
          !RegExp(r'^[A-Za-z_:][A-Za-z0-9_:.-]*$').hasMatch(field.attribute)) {
        throw const FormatException('属性名を確認してください');
      }
    }
  }

  Map<String, dynamic> toJson() => {
    'format': 'offline-comic-reader.list-extraction',
    'version': paginationUrl.isNotEmpty ? 5 : (details.isEmpty ? 3 : 4),
    'pageUrl': pageUrl,
    if (paginationUrl.isNotEmpty) 'paginationUrl': paginationUrl,
    'kind': kind,
    'acquisition': acquisition,
    'groupSelector': groupSelector,
    'fields': fields.map((key, value) => MapEntry(key, value.toJson())),
    if (details.isNotEmpty)
      'details': details.map((key, value) => MapEntry(key, value.toJson())),
  };

  String encodeJson() {
    validate();
    return const JsonEncoder.withIndent('  ').convert(toJson());
  }

  String encodeQr() {
    validate();
    final exportPrefix = paginationUrl.isNotEmpty
        ? 'ocr-list:5:'
        : (details.isEmpty ? qrPrefix : 'ocr-list:4:');
    final value =
        '$exportPrefix${base64Url.encode(utf8.encode(jsonEncode(toJson())))}';

    if (value.length > 1500) {
      throw const FormatException('この設定はQRの初版上限を超えています。JSONで共有してください');
    }
    return value;
  }

  static ListExtractionRule parse(String input) {
    var value = input.trim();

    if (utf8.encode(value).length > 65536) {
      throw const FormatException('設定が大きすぎます');
    }

    final prefix = value.startsWith('ocr-list:5:')
        ? 'ocr-list:5:'
        : value.startsWith('ocr-list:4:')
        ? 'ocr-list:4:'
        : value.startsWith(qrPrefix)
        ? qrPrefix
        : value.startsWith('ocr-list:2:')
        ? 'ocr-list:2:'
        : value.startsWith('ocr-list:1:')
        ? 'ocr-list:1:'
        : null;

    if (prefix != null) {
      value = utf8.decode(
        base64Url.decode(base64Url.normalize(value.substring(prefix.length))),
      );
    }

    if (utf8.encode(value).length > 65536) {
      throw const FormatException('設定が大きすぎます');
    }

    final data = Map<String, dynamic>.from(jsonDecode(value) as Map);

    if (data['format'] != 'offline-comic-reader.list-extraction' ||
        !const [1, 2, 3, 4, 5].contains(data['version']) ||
        data.keys.any(
          (key) => !const {
            'format',
            'version',
            'pageUrl',
            'kind',
            'acquisition',
            'groupSelector',
            'fields',
            'details',
            'paginationUrl',
          }.contains(key),
        )) {
      throw const FormatException('未対応の一覧ルールです');
    }

    if (data.containsKey('details') &&
        !const [4, 5].contains(data['version'])) {
      throw const FormatException('作品詳細設定にはバージョン4以降が必要です');
    }

    if (data.containsKey('paginationUrl') && data['version'] != 5) {
      throw const FormatException('ページ送り設定にはバージョン5が必要です');
    }

    final rawDetails = Map<String, dynamic>.from(
      (data['details'] ?? const <String, dynamic>{}) as Map,
    );
    final rawFields = Map<String, dynamic>.from(data['fields'] as Map);

    // 旧形式に存在しなかった項目だけを補う。
    if (data['version'] == 1) {
      rawFields.putIfAbsent(
        'latestChapter',
        () => const ListFieldRule(enabled: false).toJson(),
      );
    }
    final rule = ListExtractionRule(
      pageUrl: data['pageUrl'] as String,
      paginationUrl: data['paginationUrl'] as String? ?? '',
      groupSelector: data['groupSelector'] as String,
      kind: data['kind'] as String,
      acquisition: data['acquisition'] as String,
      details: rawDetails.map(
        (key, value) => MapEntry(
          key,
          ListFieldRule.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      ),
      fields: rawFields.map(
        (key, value) => MapEntry(
          key,
          ListFieldRule.fromJson(Map<String, dynamic>.from(value as Map)),
        ),
      ),
    );

    rule.validate();
    return rule;
  }
}

class ExtractedListRow {
  const ExtractedListRow(
    this.values,
    this.issues, [
    this.candidates = const <String, List<String>>{},
    this.matchCounts = const <String, int>{},
  ]);

  final Map<String, String> values;
  final List<String> issues;

  /// 設定画面用。加工前の文字列または属性値。各項目先頭50件まで。
  final Map<String, List<String>> candidates;
  final Map<String, int> matchCounts;
}

class ListExtractionReport {
  const ListExtractionReport(this.total, this.rows);

  final int total;
  final List<ExtractedListRow> rows;
}

/// 通常の url("...") / url('...') / url(...) の最初のURLを取り出す。
/// CSSエスケープや複数背景の完全解析は行わない。
String firstCssUrl(String value) {
  final match = RegExp(
    r'''url\(\s*(?:"([^"]*)"|'([^']*)'|([^)\s]+))\s*\)''',
    caseSensitive: false,
  ).firstMatch(value);

  return (match?.group(1) ?? match?.group(2) ?? match?.group(3) ?? '').trim();
}

ListExtractionReport extractListRows(
  HtmlProbePage page,
  ListExtractionRule rule, {
  int maxRows = 100,
  bool collectCandidates = false,
}) {
  if (maxRows < 1 || maxRows > 5000) {
    throw const FormatException('抽出件数は1～5000件で指定してください');
  }
  rule.validate();

  if (htmlProbeUri(rule.pageUrl) != page.uri.removeFragment()) {
    throw const FormatException('ルールのURLと取得したHTMLのURLが違います');
  }

  final document = html.parse(page.source);
  var baseUri = page.uri;
  final base = document.querySelector('base[href]')?.attributes['href'];

  if (base != null) {
    final candidate = page.uri.resolve(base);
    if (const ['https', 'http'].contains(candidate.scheme)) {
      baseUri = candidate;
    }
  }

  final List<Element> groups;
  try {
    groups = document.querySelectorAll(rule.groupSelector);
  } catch (error) {
    throw FormatException('まとまりのセレクターが不正です：$error');
  }

  final rows = <ExtractedListRow>[];

  for (final group in groups.take(maxRows)) {
    final values = <String, String>{};
    final issues = <String>[];
    final candidates = <String, List<String>>{};
    final matchCounts = <String, int>{};

    for (final entry in rule.fields.entries) {
      final key = entry.key;
      final field = entry.value;
      if (!field.enabled) continue;

      try {
        final List<Element> matches;
        if (field.selector.trim().isEmpty) {
          matches = <Element>[group];
        } else {
          try {
            matches = group.querySelectorAll(field.selector);
          } catch (error) {
            throw FormatException('項目のセレクターが不正です：$error');
          }
        }

        final element = matches.isEmpty ? null : matches.first;

        if (matches.length > 1) {
          issues.add('${listFieldLabels[key]}：${matches.length}件あるため先頭を使用');
        }

        if (collectCandidates) {
          matchCounts[key] = matches.length;
          candidates[key] = List<String>.unmodifiable(
            matches.take(50).map((candidate) {
              final raw = field.mode == ListValueMode.text
                  ? candidate.text.trim()
                  : candidate.attributes[field.attribute] ?? '';

              // 詳細プレビュー用。極端に長い値を全件保持しない。
              return raw.length > 2000
                  ? '${raw.substring(0, 2000)}…（以降省略）'
                  : raw;
            }),
          );
        }
        var value = element == null
            ? ''
            : field.mode == ListValueMode.text
            ? element.text.trim()
            : element.attributes[field.attribute] ?? '';

        if (field.mode == ListValueMode.cssUrl) {
          value = firstCssUrl(value);
        }

        value = value.trim();
        if (key == 'date' && field.localizeRelativeTime) {
          value = localizeEnglishRelativeTime(value);
        }
        value = transformListText(
          value,
          pattern: field.pattern,
          replacement: field.replacement,
        );

        if ((key == 'url' || key == 'thumbnail') && value.isNotEmpty) {
          final uri = baseUri.resolve(value);
          if (!const ['http', 'https'].contains(uri.scheme) ||
              uri.host.isEmpty ||
              uri.userInfo.isNotEmpty) {
            throw const FormatException('HTTP/HTTPSのURLではありません');
          }
          value = uri.toString();
        }

        values[key] = value;

        if ((key == 'title' || key == 'url') && value.isEmpty) {
          issues.add('${listFieldLabels[key]}：取得できません');
        }
      } catch (error) {
        values[key] = '';
        issues.add('${listFieldLabels[key]}：$error');
      }
    }

    rows.add(
      ExtractedListRow(
        Map.unmodifiable(values),
        List.unmodifiable(issues),
        Map.unmodifiable(candidates),
        Map.unmodifiable(matchCounts),
      ),
    );
  }

  return ListExtractionReport(groups.length, List.unmodifiable(rows));
}

String encodeListRuleCache(dynamic data) => jsonEncode(data);

/// 通常HTML・描画後DOMのどちらも同じ抽出処理を使用する。
/// 正規表現などの処理が長引いた場合はIsolateごと停止する。
Future<ListExtractionReport> extractListRowsSafely(
  HtmlProbePage page,
  ListExtractionRule rule, {
  int maxRows = 100,
  Duration timeout = const Duration(seconds: 3),
  bool collectCandidates = false,
}) async {
  final port = ReceivePort();
  final result = Completer<ListExtractionReport>();
  Isolate? worker;

  final subscription = port.listen((dynamic message) {
    if (result.isCompleted) return;

    if (message is List &&
        message.length == 2 &&
        message[0] == 'ok' &&
        message[1] is ListExtractionReport) {
      result.complete(message[1] as ListExtractionReport);
    } else if (message is List &&
        message.length == 2 &&
        message[0] == 'error') {
      result.completeError(FormatException(message[1].toString()));
    } else {
      result.completeError(StateError('一覧の抽出処理が終了しました：$message'));
    }
  });

  try {
    worker = await Isolate.spawn<List<Object?>>(
      _listExtractionWorker,
      <Object?>[port.sendPort, page, rule, maxRows, collectCandidates],
      onError: port.sendPort,
      onExit: port.sendPort,
      errorsAreFatal: true,
    );

    return await result.future.timeout(
      timeout,
      onTimeout: () => throw const FormatException(
        '一覧テストが時間上限を超えました。'
        '正規表現やセレクターを簡単にしてください',
      ),
    );
  } finally {
    worker?.kill(priority: Isolate.immediate);
    await subscription.cancel();
    port.close();
  }
}

void _listExtractionWorker(List<Object?> input) {
  final port = input[0] as SendPort;
  try {
    final report = extractListRows(
      input[1] as HtmlProbePage,
      input[2] as ListExtractionRule,
      maxRows: input[3] as int,
      collectCandidates: input[4] as bool,
    );
    port.send(<Object?>['ok', report]);
  } catch (error) {
    port.send(<Object?>['error', error.toString()]);
  }
}
