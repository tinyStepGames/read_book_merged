import 'dart:convert';

import 'chapter_image_rule.dart';

/// URL抽出の準備状態。画像本体のダウンロード完了とは区別する。
class RenderedImageReadinessSample {
  const RenderedImageReadinessSample({
    required this.url,
    required this.readyState,
    required this.count,
    required this.validCount,
    required this.signature,
  });

  final String url;
  final String readyState;
  final int count;
  final int validCount;
  final String signature;

  bool get usable =>
      (readyState == 'interactive' || readyState == 'complete') &&
      count > 0 &&
      validCount == count &&
      signature.isNotEmpty;

  String get stabilityKey => jsonEncode([url, count, signature]);

  factory RenderedImageReadinessSample.decode(Map<String, dynamic> value) {
    final url = value['url'];
    final ready = value['ready'];
    final count = value['count'];
    final valid = value['validCount'];
    final signature = value['signature'];

    if (url is! String ||
        ready is! String ||
        count is! int ||
        valid is! int ||
        count < 0 ||
        count > 2000 ||
        valid < 0 ||
        valid > count ||
        signature is! String ||
        signature.length > 128) {
      throw const FormatException('本文画像の準備状態が不正です');
    }

    return RenderedImageReadinessSample(
      url: url,
      readyState: ready,
      count: count,
      validCount: valid,
      signature: signature,
    );
  }
}

/// 本文外の広告・時刻・HTMLサイズを判定に含めない。
/// 安定は完全性の証明ではないため、取得後の既存抽出検証も必ず通す。
class RenderedImageStability {
  String? _key;
  DateTime? _since;

  void reset() {
    _key = null;
    _since = null;
  }

  bool observe(RenderedImageReadinessSample sample, DateTime now) {
    if (!sample.usable) {
      reset();
      return false;
    }

    final key = sample.stabilityKey;
    if (_key != key || _since == null || now.isBefore(_since!)) {
      _key = key;
      _since = now;
      return false;
    }

    return now.difference(_since!) >= const Duration(seconds: 2);
  }
}

String renderedImageReadinessScript({
  required String selector,
  required String attribute,
}) {
  final rule = ChapterImageRule(selector: selector, attribute: attribute);
  rule.validate();

  final encodedSelector = jsonEncode(selector.trim());
  final encodedAttribute = jsonEncode(attribute.trim());

  return '''
(() => {
  const selector = $encodedSelector;
  const attribute = $encodedAttribute;
''' +
      r'''
  const elements = [...document.querySelectorAll(selector)];
  if (elements.length > 2000) {
    throw new Error('画像候補が2000件を超えています');
  }

  let validCount = 0;
  let hashA = 2166136261;
  let hashB = 5381;
  let length = 0;

  function feed(text) {
    length += text.length;
    for (let index = 0; index < text.length; index++) {
      const code = text.charCodeAt(index);
      hashA = Math.imul(hashA ^ code, 16777619) >>> 0;
      hashB = (Math.imul(hashB, 33) ^ code) >>> 0;
    }
    // URL同士の境界も署名に含める。
    hashA = Math.imul(hashA ^ 0, 16777619) >>> 0;
    hashB = Math.imul(hashB, 33) >>> 0;
  }

  for (const element of elements) {
    const raw = (element.getAttribute(attribute) || '').trim();
    let value = raw;

    try {
      if (!raw || raw.length > 8192 ||
          /[\s\u0000-\u001f\u007f\\]/.test(raw)) {
        throw new Error('画像URLが未準備です');
      }

      const url = new URL(raw, document.baseURI);
      if (url.protocol !== 'https:' || !url.hostname ||
          url.username || url.password) {
        throw new Error('画像URLが未対応です');
      }

      url.hash = '';
      value = url.href;
      validCount++;
    } catch (_) {
      // 不正候補を無視して取得完了にはしない。
    }

    feed(value);
  }

  return JSON.stringify({
    url: location.href,
    ready: document.readyState,
    count: elements.length,
    validCount,
    signature: hashA.toString(16) + ':' +
      hashB.toString(16) + ':' + length
  });
})()
''';
}
