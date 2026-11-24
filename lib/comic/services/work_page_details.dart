import 'work_tag_link.dart';
import 'dart:async';
import 'dart:isolate';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

import 'html_probe.dart';
import 'list_extraction_rule.dart';
import 'list_text_transform.dart';

class WorkPageDetails {
  const WorkPageDetails({
    this.title = '',
    this.thumbnail,
    this.description = '',
    this.tags = const [],
    this.tagLinks = const [],
    this.chapterNumbers = const [],
    this.issues = const [],
  });

  final String title;
  final Uri? thumbnail;
  final String description;
  final List<String> tags;
  final List<WorkTagLink> tagLinks;
  final List<String> chapterNumbers;
  final List<String> issues;
}

String _readValue(Element element, ListFieldRule field) {
  String raw;
  if (field.mode == ListValueMode.text) {
    final copy = element.clone(true);
    for (final br in copy.querySelectorAll('br')) {
      br.replaceWith(Text('\n'));
    }
    for (final block in copy.querySelectorAll('p, div, li')) {
      block.nodes.insert(0, Text('\n'));
    }
    raw = copy.text.trim();
  } else {
    raw = element.attributes[field.attribute] ?? '';
  }

  if (field.mode == ListValueMode.cssUrl) raw = firstCssUrl(raw);

  if (raw.length > 32768) {
    throw const FormatException('取得文字列が長すぎます。範囲を狭めてください');
  }

  return transformListText(
    raw.trim(),
    pattern: field.pattern,
    replacement: field.replacement,
  ).trim();
}

WorkPageDetails extractWorkPageDetails(
  HtmlProbePage page,
  ListExtractionRule rule,
) {
  rule.validate();
  if (htmlProbeUri(rule.pageUrl) != page.uri.removeFragment()) {
    throw const FormatException('作品詳細のURLが一致しません');
  }

  final document = html.parse(page.source);
  final issues = <String>[];
  final values = <String, String>{};
  final tags = <String>[];
  final tagLinks = <WorkTagLink>[];
  final numbers = <String>[];

  var baseUri = page.uri;
  final base = document.querySelector('base[href]')?.attributes['href'];
  if (base != null) {
    final candidate = page.uri.resolve(base);
    if (candidate.scheme == 'https' && candidate.userInfo.isEmpty) {
      baseUri = candidate;
    }
  }

  for (final entry in rule.details.entries) {
    final key = entry.key;
    final field = entry.value;
    if (!field.enabled || key == 'chapterNumber') continue;

    try {
      final elements = document.querySelectorAll(field.selector);
      if (elements.isEmpty) {
        issues.add('${workDetailLabels[key]}：一致する要素がありません');
        continue;
      }

      if (key == 'tags') {
        if (elements.length > 100) {
          issues.add('タグ：先頭100件まで取得しました');
        }
        for (final element in elements.take(100)) {
          try {
            final value = _readValue(element, field);
            if (value.isEmpty) continue;

            if (!tags.contains(value)) {
              tags.add(value);
            }

            final link = workTagLinkForElement(
              element: element,
              label: value,
              pageUri: page.uri,
              baseUri: baseUri,
            );

            if (link != null &&
                !tagLinks.any((item) => item.label == link.label)) {
              tagLinks.add(link);
            }
          } catch (error) {
            issues.add('タグ：$error');
          }
        }
      } else {
        if (elements.length > 1) {
          issues.add('${workDetailLabels[key]}：${elements.length}件あるため先頭を使用');
        }
        values[key] = _readValue(elements.first, field);
      }
    } catch (error) {
      issues.add('${workDetailLabels[key]}：$error');
    }
  }

  final numberField = rule.details['chapterNumber'];
  if (numberField?.enabled == true) {
    final groups = document.querySelectorAll(rule.groupSelector);
    for (final group in groups.take(5000)) {
      try {
        // :scope は1話のまとまり自身を表す。
        final element = numberField!.selector.trim() == ':scope'
            ? group
            : group.querySelector(numberField.selector);
        final value = element == null ? '' : _readValue(element, numberField);
        numbers.add(value);
      } catch (_) {
        numbers.add('');
      }
    }
    final invalid = numbers
        .where((value) => parseChapterNumber(value) == null)
        .length;
    if (invalid > 0) {
      issues.add('並び替え用の話数：$invalid件は数値化できません');
    }
  }

  Uri? thumbnail;
  final rawImage = values['thumbnail'] ?? '';
  if (rawImage.isNotEmpty) {
    try {
      thumbnail = htmlProbeUri(baseUri.resolve(rawImage).toString());
    } catch (_) {
      issues.add('表紙：認証情報を含まないHTTPSの画像URLにしてください');
    }
  }

  return WorkPageDetails(
    title: values['title'] ?? '',
    thumbnail: thumbnail,
    description: values['description'] ?? '',
    tags: List.unmodifiable(tags),
    tagLinks: List.unmodifiable(tagLinks),
    chapterNumbers: List.unmodifiable(numbers),
    issues: List.unmodifiable(issues),
  );
}

/// 正規表現を含む処理は別Isolateで実行し、時間超過時には停止する。
Future<WorkPageDetails> extractWorkPageDetailsSafely(
  HtmlProbePage page,
  ListExtractionRule rule, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final port = ReceivePort();
  final result = Completer<WorkPageDetails>();
  Isolate? worker;

  final subscription = port.listen((dynamic message) {
    if (result.isCompleted) return;
    if (message is List &&
        message.length == 2 &&
        message[0] == 'ok' &&
        message[1] is WorkPageDetails) {
      result.complete(message[1] as WorkPageDetails);
    } else {
      result.completeError(FormatException('作品詳細の抽出に失敗しました：$message'));
    }
  });

  try {
    worker = await Isolate.spawn<List<Object?>>(
      _workDetailsWorker,
      [port.sendPort, page, rule],
      onError: port.sendPort,
      onExit: port.sendPort,
      errorsAreFatal: true,
    );

    return await result.future.timeout(
      timeout,
      onTimeout: () =>
          throw const FormatException('作品詳細の抽出が時間上限を超えました。正規表現や範囲を簡単にしてください'),
    );
  } finally {
    worker?.kill(priority: Isolate.immediate);
    await subscription.cancel();
    port.close();
  }
}

void _workDetailsWorker(List<Object?> args) {
  final port = args[0] as SendPort;
  try {
    port.send([
      'ok',
      extractWorkPageDetails(
        args[1] as HtmlProbePage,
        args[2] as ListExtractionRule,
      ),
    ]);
  } catch (error) {
    port.send(['error', error.toString()]);
  }
}

enum ChapterListOrder { source, reverse, ascending, descending }

double? parseChapterNumber(String value) {
  final trimmed = value.trim();
  if (!RegExp(r'^\d+(?:\.\d+)?$').hasMatch(trimmed)) return null;
  final number = double.tryParse(trimmed);
  return number != null && number.isFinite ? number : null;
}

List<T> sortChapterItems<T>(
  List<T> source,
  String Function(T) numberOf,
  ChapterListOrder order,
) {
  if (order == ChapterListOrder.source) return List.of(source);
  if (order == ChapterListOrder.reverse) return source.reversed.toList();

  final indexed = source.asMap().entries.toList();
  indexed.sort((a, b) {
    final x = parseChapterNumber(numberOf(a.value));
    final y = parseChapterNumber(numberOf(b.value));

    if (x == null && y == null) return a.key.compareTo(b.key);
    if (x == null) return 1;
    if (y == null) return -1;

    final compared = order == ChapterListOrder.ascending
        ? x.compareTo(y)
        : y.compareTo(x);
    return compared == 0 ? a.key.compareTo(b.key) : compared;
  });

  return indexed.map((entry) => entry.value).toList();
}
