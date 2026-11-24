import 'dart:async';
import 'dart:isolate';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html;

Future<List<Map<String, Object?>>> checkSelectorCandidates({
  required String source,
  required List<String> selectors,
  String scope = '',
  String valueMode = 'text',
  String attribute = '',
}) async {
  if (source.length > 2 * 1024 * 1024 ||
      selectors.isEmpty ||
      selectors.length > 10 ||
      selectors.any((value) => value.length > 8192) ||
      scope.length > 8192) {
    throw const FormatException('セレクター確認の入力が上限を超えています');
  }

  final port = ReceivePort();
  Isolate? worker;

  try {
    worker = await Isolate.spawn(_selectorCheckWorker, <Object?>[
      port.sendPort,
      source,
      selectors,
      scope,
      valueMode,
      attribute,
    ]);

    final message = await port.first.timeout(const Duration(seconds: 4));

    final values = message as List;
    if (values.first != 'ok') {
      throw FormatException(values[1].toString());
    }

    return (values[1] as List)
        .map((value) => Map<String, Object?>.from(value as Map))
        .toList();
  } finally {
    worker?.kill(priority: Isolate.immediate);
    port.close();
  }
}

// 位置系の関数はブラウザーとHTMLパーサーで扱いが異なる場合がある。
// この確認画面では保守的に採用しない。
// 実際の抽出エンジン全体の対応可否を定義するものではない。
void _checkSelectorPolicy(String selector) {
  if (RegExp(
    r':(?:nth-[a-z-]+|has|is|where)\s*\(',
    caseSensitive: false,
  ).hasMatch(selector)) {
    throw const FormatException(
      'この確認画面では採用しない関数が含まれています。'
      'ID・クラス・属性・親子関係・隣接関係の候補を選んでください',
    );
  }
}

void _selectorCheckWorker(List<Object?> input) {
  final port = input[0] as SendPort;

  try {
    final document = html.parse(input[1] as String);
    final selectors = List<String>.from(input[2] as List);
    final scope = input[3] as String;
    final mode = input[4] as String;
    final attribute = input[5] as String;

    String? scopeError;
    List<Element> groups = [];

    if (scope.isNotEmpty) {
      try {
        _checkSelectorPolicy(scope);
        groups = document.querySelectorAll(scope);
        if (groups.isEmpty) {
          scopeError = 'まとまりが表示後HTMLに見つかりません';
        }
      } catch (error) {
        scopeError = 'まとまりのセレクターを確認してください：$error';
      }
    }

    final results = <Map<String, Object?>>[];

    for (final selector in selectors) {
      var count = 0;
      var errorText = '';
      final previews = <String>[];

      try {
        if (scopeError != null) {
          throw FormatException(scopeError);
        }

        _checkSelectorPolicy(selector);

        final elements = <Element>{};
        if (scope.isEmpty) {
          if (selector.isEmpty) {
            throw const FormatException('セレクターが空です');
          }
          elements.addAll(document.querySelectorAll(selector));
        } else {
          for (final group in groups) {
            if (selector.isEmpty) {
              elements.add(group);
            } else {
              elements.addAll(group.querySelectorAll(selector));
            }
          }
        }

        count = elements.length;

        for (final element in elements.take(3)) {
          final value = switch (mode) {
            'innerHtml' => element.innerHtml,
            'attribute' => element.attributes[attribute] ?? '',
            _ => element.text,
          };

          final trimmed = value.trim();
          previews.add(
            trimmed.length > 240 ? '${trimmed.substring(0, 240)}…' : trimmed,
          );
        }
      } catch (error) {
        errorText = error.toString();
      }

      results.add({
        'selector': selector,
        'count': count,
        'error': errorText,
        'previews': previews,
      });
    }

    port.send(<Object?>['ok', results]);
  } catch (error) {
    port.send(<Object?>['error', error.toString()]);
  }
}
