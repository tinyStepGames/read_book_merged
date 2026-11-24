import 'dart:typed_data';
import 'dart:ui';

import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

typedef SiteQrPhotoWriter = Future<void> Function(Uint8List bytes);

typedef SiteQrShareInvoker = Future<ShareResult> Function(ShareParams params);

void _checkPng(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];

  if (bytes.length < signature.length) {
    throw const FormatException('QRのPNG画像が不正です');
  }

  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) {
      throw const FormatException('QRのPNG画像が不正です');
    }
  }
}

/// QR画像を写真ライブラリへ保存する。
/// 共有操作では呼び出さない。
Future<void> saveSiteQrToPhotos(
  Uint8List bytes, {
  SiteQrPhotoWriter? writer,
}) async {
  _checkPng(bytes);

  if (writer != null) {
    await writer(bytes);
    return;
  }

  try {
    var allowed = await Gal.hasAccess();

    if (!allowed) {
      allowed = await Gal.requestAccess();
    }

    if (!allowed) {
      throw StateError(
        '写真への保存が許可されていません。'
        '端末の設定でこのアプリの写真への追加を許可するか、'
        '画像共有・PNG保存をご利用ください',
      );
    }

    await Gal.putImageBytes(
      bytes,
      name: 'site-rule-${DateTime.now().millisecondsSinceEpoch}',
    );
  } on GalException catch (error) {
    if (error.type == GalExceptionType.accessDenied) {
      throw StateError(
        '写真への保存が許可されていません。'
        '端末の設定で権限を確認してください',
      );
    }

    throw StateError('写真への保存に失敗しました：${error.type.message}');
  }
}

/// QR画像だけをOS標準の共有画面へ渡す。
/// 共有前に写真へ保存する必要はない。
Future<String> shareSiteQrImage(
  Uint8List bytes, {
  required Rect origin,
  SiteQrShareInvoker? invoker,
}) async {
  _checkPng(bytes);

  if (!origin.left.isFinite ||
      !origin.top.isFinite ||
      !origin.width.isFinite ||
      !origin.height.isFinite ||
      origin.width <= 0 ||
      origin.height <= 0) {
    throw const FormatException('共有画面の表示位置が不正です');
  }

  final params = ShareParams(
    files: [XFile.fromData(bytes, mimeType: 'image/png')],
    fileNameOverrides: const ['site-rule.png'],
    title: 'サイト設定のQR',
    sharePositionOrigin: origin,
  );

  final result = invoker == null
      ? await SharePlus.instance.share(params)
      : await invoker(params);

  return switch (result.status) {
    ShareResultStatus.success =>
      '共有操作が完了しました。'
          '相手への送信状況は共有先アプリで確認してください。',
    ShareResultStatus.dismissed => '共有を閉じました。',
    ShareResultStatus.unavailable =>
      '共有画面へ画像を渡しました。'
          '共有結果は共有先アプリで確認してください。',
  };
}
