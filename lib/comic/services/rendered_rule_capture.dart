import 'dart:convert';

import 'html_probe.dart';

HtmlProbePage decodeRenderedRulePage(
  String raw, {
  required String allowedOrigin,
}) {
  if (raw.length > 3 * 1024 * 1024) {
    throw const FormatException('表示後HTMLの応答が大きすぎます');
  }

  final decoded = jsonDecode(raw);
  if (decoded is! Map ||
      decoded['url'] is! String ||
      decoded['source'] is! String) {
    throw const FormatException('表示後HTMLを読み取れませんでした');
  }

  final uri = htmlProbeUri(decoded['url'] as String);
  if (uri.origin != allowedOrigin) {
    throw const FormatException('設定した取得元とは異なるページです');
  }

  final source = decoded['source'] as String;
  final bytes = utf8.encode(source).length;

  if (bytes > HtmlProbeClient.maxBytes) {
    throw const FormatException('表示後HTMLが上限の2MiBを超えています');
  }
  if (source.trim().isEmpty) {
    throw const FormatException('表示後HTMLが空です');
  }

  return HtmlProbePage(uri: uri, source: source, bytes: bytes);
}
