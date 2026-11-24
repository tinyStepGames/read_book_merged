import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// ボタンやタイトルを含めず、QR画像だけをPNGにする。
Future<Uint8List> createSiteQrPng(String payload) async {
  if (payload.isEmpty || payload.length > 2200) {
    throw const FormatException('QR内容の長さが不正です');
  }

  final validation = QrValidator.validate(
    data: payload,
    version: QrVersions.auto,
    errorCorrectionLevel: QrErrorCorrectLevel.M,
  );

  final qr = validation.qrCode;

  if (validation.status != QrValidationStatus.valid || qr == null) {
    throw FormatException(
      'QR画像を生成できません：'
      '${validation.error ?? 'QRデータが不正です'}',
    );
  }

  // 四方に4モジュール分の白い余白を付ける。
  const quietModules = 4;
  final totalModules = qr.moduleCount + quietModules * 2;

  // 各モジュールを整数ピクセルで描画する。
  final scale = (1600 / totalModules).floor().clamp(4, 24).toInt();

  final side = totalModules * scale;
  final border = quietModules * scale;
  final codeSide = qr.moduleCount * scale;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);

  canvas.drawRect(
    Rect.fromLTWH(0, 0, side.toDouble(), side.toDouble()),
    Paint()..color = Colors.white,
  );

  canvas.save();

  canvas.translate(border.toDouble(), border.toDouble());

  final painter = QrPainter.withQr(
    qr: qr,
    gapless: true,
    eyeStyle: const QrEyeStyle(
      eyeShape: QrEyeShape.square,
      color: Colors.black,
    ),
    dataModuleStyle: const QrDataModuleStyle(
      dataModuleShape: QrDataModuleShape.square,
      color: Colors.black,
    ),
  );

  painter.paint(canvas, Size.square(codeSide.toDouble()));

  canvas.restore();

  final picture = recorder.endRecording();

  try {
    final image = await picture.toImage(side, side);

    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);

      if (data == null) {
        throw StateError('PNG画像への変換に失敗しました');
      }

      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}
