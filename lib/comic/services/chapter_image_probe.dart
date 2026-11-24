import 'dart:async';
import 'dart:isolate';

import 'chapter_image_rule.dart';
import 'html_probe.dart';

Future<ChapterImageReport> probeChapterImages({
  required HtmlProbePage page,
  required ChapterImageRule rule,
}) async {
  // 画面側でも、重いHTML解析をメインIsolateで実行しない。
  rule.validate();

  final port = ReceivePort();
  Isolate? worker;

  try {
    worker = await Isolate.spawn(_chapterImageProbeWorker, <Object?>[
      port.sendPort,
      page,
      rule,
    ]);

    final raw = await port.first.timeout(const Duration(seconds: 4));

    final message = raw as List;
    if (message.first != 'ok') {
      throw FormatException(message[1].toString());
    }

    return message[1] as ChapterImageReport;
  } on TimeoutException {
    throw const FormatException('画像抽出が4秒を超えました。本文部分にセレクターを絞ってください');
  } finally {
    worker?.kill(priority: Isolate.immediate);
    port.close();
  }
}

void _chapterImageProbeWorker(List<Object?> input) {
  final port = input[0] as SendPort;

  try {
    final report = extractChapterImages(
      page: input[1] as HtmlProbePage,
      rule: input[2] as ChapterImageRule,
    );
    port.send(<Object?>['ok', report]);
  } catch (error) {
    port.send(<Object?>['error', error.toString()]);
  }
}
