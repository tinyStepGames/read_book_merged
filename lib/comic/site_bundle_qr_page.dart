import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:super_clipboard/super_clipboard.dart' as rich_clipboard;

import 'services/site_qr_png.dart';
import 'services/site_qr_actions.dart';

class SiteBundleQrPage extends StatefulWidget {
  const SiteBundleQrPage({
    super.key,
    required this.payload,
    required this.siteName,
  });

  final String payload;
  final String siteName;

  @override
  State<SiteBundleQrPage> createState() => _SiteBundleQrPageState();
}

class _SiteBundleQrPageState extends State<SiteBundleQrPage> {
  Future<Uint8List>? _png;
  bool _busy = false;
  final GlobalKey _shareButtonKey = GlobalKey();
  String _status = '';

  bool get _canSavePhotos => Platform.isIOS || Platform.isAndroid;

  Future<void> _saveToPhotos() => _run(() async {
    final bytes = await _imageBytes();

    if (!mounted) {
      return '写真への保存を取り消しました。';
    }

    await saveSiteQrToPhotos(bytes);

    return 'QR画像を写真ライブラリへ保存しました。';
  });

  Future<void> _shareImage() => _run(() async {
    final bytes = await _imageBytes();

    if (!mounted) {
      return '共有を取り消しました。';
    }

    final renderObject = _shareButtonKey.currentContext?.findRenderObject();

    if (renderObject is! RenderBox ||
        !renderObject.hasSize ||
        renderObject.size.isEmpty) {
      throw StateError(
        '共有ボタンの位置を取得できませんでした。'
        '画面を開き直して再試行してください',
      );
    }

    // iPadの共有ポップオーバーに必要な起点。
    final origin = renderObject.localToGlobal(Offset.zero) & renderObject.size;

    return shareSiteQrImage(bytes, origin: origin);
  });
  Future<Uint8List> _imageBytes() => _png ??= createSiteQrPng(widget.payload);

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;

    setState(() {
      _busy = true;
      _status = '処理中…';
    });

    try {
      final message = await action();

      if (mounted) {
        setState(() => _status = message);
      }
    } catch (error) {
      // PNG生成が失敗した場合も、次の操作で再試行できるようにする。
      _png = null;

      if (mounted) {
        setState(() => _status = '処理できませんでした：$error');
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _copyImage() => _run(() async {
    final bytes = await _imageBytes();

    final clipboard = rich_clipboard.SystemClipboard.instance;

    if (clipboard == null) {
      throw UnsupportedError(
        'この環境では画像コピーを利用できません。'
        'PNGで保存してください',
      );
    }

    final item = rich_clipboard.DataWriterItem();

    item.add(rich_clipboard.Formats.png(bytes));

    await clipboard.write([item]);

    return 'QR画像をコピーしました。'
        '画像の貼り付けに対応したアプリへ貼り付けられます。';
  });

  Future<void> _saveImage() => _run(() async {
    final bytes = await _imageBytes();

    if (!mounted) {
      return '保存を取り消しました。';
    }

    final name = 'site-rule-${DateTime.now().millisecondsSinceEpoch}';

    final saved = await FileSaver.instance.saveAs(
      name: name,
      bytes: bytes,
      fileExtension: 'png',
      mimeType: MimeType.png,
    );

    if (saved == null || saved.isEmpty) {
      return '保存をキャンセルしました。';
    }

    return 'PNG画像を保存しました。\n$saved';
  });

  Future<void> _copyText() => _run(() async {
    await Clipboard.setData(ClipboardData(text: widget.payload));

    return 'QR内容の文字列をコピーしました。'
        'これは画像ではありません。'
        '取り込み画面の入力欄へ貼り付けて使えます。';
  });

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(title: const Text('サイト設定のQR')),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              widget.siteName,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final side = math.min(
                  720.0,
                  math.min(
                    constraints.maxWidth - 32,
                    constraints.maxHeight - 32,
                  ),
                );

                if (!side.isFinite || side < 120) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        'QRの表示領域が足りません。\n'
                        '画面を縦向きにするか、'
                        'ウィンドウを広げてください。\n'
                        '画像コピー・PNG保存は'
                        '下のボタンから使えます。',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  );
                }

                return Center(
                  child: SizedBox.square(
                    dimension: side,
                    child: ColoredBox(
                      color: Colors.white,
                      child: QrImageView(
                        key: const ValueKey('site-bundle-qr-image'),
                        data: widget.payload,
                        size: side,
                        padding: const EdgeInsets.all(24),
                        version: QrVersions.auto,
                        errorCorrectionLevel: QrErrorCorrectLevel.M,
                        backgroundColor: Colors.white,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Colors.black,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Colors.black,
                        ),
                        errorStateBuilder: (context, error) => Padding(
                          padding: const EdgeInsets.all(16),
                          child: Center(
                            child: SingleChildScrollView(
                              child: Text(
                                'QR画像を生成'
                                'できませんでした。\n\n'
                                '${error ?? '原因不明のエラー'}'
                                '\n\n'
                                '戻ってJSON共有を'
                                '使用してください。',
                                style: const TextStyle(color: Colors.black),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _busy ? null : _copyImage,
                  icon: const Icon(Icons.copy),
                  label: const Text('画像をコピー'),
                ),
                if (_canSavePhotos)
                  FilledButton.icon(
                    onPressed: _busy ? null : _saveToPhotos,
                    icon: const Icon(Icons.photo_library_outlined),
                    label: const Text('写真に保存'),
                  ),
                FilledButton.icon(
                  key: _shareButtonKey,
                  onPressed: _busy ? null : _shareImage,
                  icon: const Icon(Icons.ios_share),
                  label: const Text('画像を共有'),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _saveImage,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('PNGで保存'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _copyText,
                  child: const Text('文字列をコピー'),
                ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_status.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 88),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: SelectableText(_status, textAlign: TextAlign.center),
              ),
            ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              'この1枚にサイト設定一式が入っています。\n'
              '写真に保存・画像共有・ファイル保存を選べます。',
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    ),
  );
}
