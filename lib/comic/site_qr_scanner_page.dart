import 'dart:async';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'services/site_rule_bundle.dart';

/// カメラと画像解析を差し替え可能にし、ルート競合を端末なしでも検証する。
abstract class SiteQrScannerBackend {
  Stream<List<String>> get codes;
  Widget preview();
  Future<void> start();
  Future<void> stop();
  Future<List<String>> analyze(String path);
  Future<void> dispose();
}

String validateSiteQrPayload(String value) {
  final text = value.trim();
  if (!text.startsWith(SiteRuleBundle.prefix)) {
    throw const FormatException('非対応のQRです。「サイト一式のJSON・QR」で作成したQRを読み取ってください。');
  }
  try {
    SiteRuleBundle.parse(text);
  } catch (error) {
    throw FormatException('QRは読めましたが、サイト設定を解析できません：$error');
  }
  return text;
}

String _cameraMessage(Object error) {
  if (error is MobileScannerException &&
      error.errorCode == MobileScannerErrorCode.permissionDenied) {
    return 'カメラの使用が許可されていません。'
        '端末の設定からこのアプリのカメラ使用を許可してください。'
        '「写真から読み取る」も使用できます。';
  }
  return 'カメラを起動・使用できませんでした。'
      'カメラの使用許可や、ほかのアプリによる使用状況を確認してください。'
      '「写真から読み取る」も使用できます。\n$error';
}

class _MobileQrBackend implements SiteQrScannerBackend {
  final _controller = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
  );

  @override
  Stream<List<String>> get codes => _controller.barcodes.map(
    (capture) => [
      for (final barcode in capture.barcodes)
        if (barcode.rawValue != null) barcode.rawValue!,
    ],
  );

  @override
  Widget preview() => MobileScanner(
    controller: _controller,
    useAppLifecycleState: false,
    errorBuilder: (context, error) => Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Text(
          _cameraMessage(error),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white),
        ),
      ),
    ),
    placeholderBuilder: (_) => const Center(child: CircularProgressIndicator()),
  );

  @override
  Future<void> start() async {
    await _controller.start();
    final error = _controller.value.error;
    if (error != null) throw error;
  }

  @override
  Future<void> stop() => _controller.stop();

  @override
  Future<List<String>> analyze(String path) async {
    final capture = await _controller.analyzeImage(
      path,
      formats: const [BarcodeFormat.qrCode],
    );
    return [
      for (final barcode in capture?.barcodes ?? <Barcode>[])
        if (barcode.rawValue != null) barcode.rawValue!,
    ];
  }

  @override
  Future<void> dispose() => _controller.dispose();
}

class SiteQrScannerPage extends StatefulWidget {
  const SiteQrScannerPage({super.key, this.backend, this.pickImage});

  /// テスト用。指定時も、この画面が停止・解放を担当する。
  final SiteQrScannerBackend? backend;
  final Future<String?> Function()? pickImage;

  @override
  State<SiteQrScannerPage> createState() => _SiteQrScannerPageState();
}

class _SiteQrScannerPageState extends State<SiteQrScannerPage>
    with WidgetsBindingObserver {
  late final SiteQrScannerBackend _backend;
  StreamSubscription<List<String>>? _subscription;

  ModalRoute<String>? _route;
  NavigatorState? _navigator;
  bool _reconcileScheduled = false;

  Future<void> _operations = Future<void>.value();
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  bool _closed = false;
  bool _disposed = false;
  bool _finishing = false;
  bool _photoBusy = false;
  String? _pending;
  String _status = 'サイト一式のQRを写すか、写真から選択してください。';

  bool get _ownsTopRoute {
    final route = _route;
    final navigator = _navigator;
    return !_closed &&
        !_disposed &&
        mounted &&
        route != null &&
        navigator != null &&
        navigator.mounted &&
        identical(route.navigator, navigator) &&
        route.isActive &&
        route.isCurrent;
  }

  bool get _stableRoute =>
      _ownsTopRoute &&
      _navigator?.userGestureInProgress != true &&
      (_route?.animation == null ||
          _route!.animation!.status == AnimationStatus.completed);

  bool get _foreground => _lifecycle == AppLifecycleState.resumed;

  bool get _wantCamera =>
      _stableRoute &&
      _foreground &&
      !_photoBusy &&
      !_finishing &&
      _pending == null;

  @override
  void initState() {
    super.initState();
    _backend = widget.backend ?? _MobileQrBackend();
    _lifecycle =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _subscription = _backend.codes.listen(
      (values) {
        if (_wantCamera) _accept(values);
      },
      onError: (Object error, StackTrace stack) {
        if (_wantCamera) _message('QRの検出に失敗しました：$error');
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of<String>(context);
    final navigator = Navigator.of(context);

    if (!identical(route, _route) || !identical(navigator, _navigator)) {
      _route?.animation?.removeStatusListener(_animationChanged);
      _navigator?.userGestureInProgressNotifier.removeListener(
        _scheduleReconcile,
      );

      _route = route;
      _navigator = navigator;

      _route?.animation?.addStatusListener(_animationChanged);
      _navigator?.userGestureInProgressNotifier.addListener(_scheduleReconcile);
    }
    _scheduleReconcile();
  }

  void _animationChanged(AnimationStatus status) {
    _scheduleReconcile();
  }

  // フレーム描画の発生を待たない。ジェスチャー／遷移完了の通知で再確認する。
  void _scheduleReconcile() {
    if (_closed || _disposed || !mounted || _reconcileScheduled) return;
    _reconcileScheduled = true;
    scheduleMicrotask(() {
      _reconcileScheduled = false;
      if (_closed || _disposed || !mounted) return;
      if (_pending != null && _stableRoute && _foreground) {
        unawaited(_finish());
      } else {
        _syncCamera();
      }
    });
  }

  // start / stop / analyze / dispose を同じ列で実行する。
  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _operations.then((_) => operation());
    _operations = next.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return next;
  }

  void _syncCamera() {
    if (_disposed) return;
    unawaited(
      _enqueue(() async {
        if (_disposed) return;
        if (_wantCamera) {
          await _backend.start();
          // 権限ダイアログなど、start待機中に状態が変わる場合も停止する。
          if (!_wantCamera) await _backend.stop();
        } else {
          await _backend.stop();
        }
      }).catchError((Object error) {
        if (_wantCamera) _message(_cameraMessage(error));
      }),
    );
  }

  void _message(String value) {
    if (!mounted || _closed || _disposed || value == _status) return;
    setState(() => _status = value);
  }

  void _accept(List<String> values) {
    if (!_stableRoute ||
        !_foreground ||
        _closed ||
        _pending != null ||
        _finishing) {
      return;
    }

    String? reason;
    for (final value in values) {
      if (value.trim().isEmpty) continue;
      try {
        final checked = validateSiteQrPayload(value);
        _pending = checked;
        _message('QRを確認しました。カメラを停止しています…');
        unawaited(_finish());
        return;
      } on FormatException catch (error) {
        // 同じ画像に複数のQRがある場合、有効なものを先に探し切る。
        if (value.trim().startsWith(SiteRuleBundle.prefix) || reason == null) {
          reason = error.message;
        }
      }
    }
    _message(reason ?? 'QRを検出できませんでした。QR全体が写った画像を選んでください。');
  }

  Future<void> _finish() async {
    if (_finishing || _pending == null || !_stableRoute || !_foreground) {
      return;
    }

    _finishing = true;
    try {
      await _enqueue(() => _backend.stop());

      // 停止待ち中に戻る・別画面・休止へ移った場合は絶対にpopしない。
      if (!_stableRoute || !_foreground || _pending == null) return;

      final value = _pending!;
      final navigator = _navigator!;

      // 上の判定からpopまでawaitを挟まない。
      _markClosed();
      navigator.pop<String>(value);
    } catch (error) {
      _pending = null;
      _message('カメラを停止できませんでした。戻るか、再試行してください。\n$error');
    } finally {
      _finishing = false;
      if (!_closed && !_disposed && _pending != null) {
        _scheduleReconcile();
      }
    }
  }

  void _markClosed() {
    _closed = true;
    _pending = null;
    // 予約済み処理は_closedを確認して終了する。
    _reconcileScheduled = false;
  }

  void _back() {
    if (!_ownsTopRoute || _navigator?.userGestureInProgress == true) return;
    final navigator = _navigator!;
    _markClosed();
    _syncCamera();
    navigator.pop<String>();
  }

  Future<String?> _chooseImage() async {
    final pick = widget.pickImage;
    if (pick != null) return pick();

    final image = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      requestFullMetadata: false,
    );
    return image?.path;
  }

  Future<void> _readPhoto() async {
    if (!_stableRoute ||
        !_foreground ||
        _photoBusy ||
        _pending != null ||
        _finishing) {
      return;
    }

    setState(() => _photoBusy = true);
    try {
      await _enqueue(() => _backend.stop());
      if (!_stableRoute || !_foreground) return;

      final path = await _chooseImage();
      if (!_ownsTopRoute) return;

      if (path == null) {
        _message('写真の選択をキャンセルしました。');
        return;
      }

      final values = <String>[];
      await _enqueue(() async {
        if (_disposed || _closed) return;
        values.addAll(await _backend.analyze(path));
      });

      if (!_ownsTopRoute) return;
      if (!_foreground || !_stableRoute) {
        _message('画面に戻ってから、写真の読み取りをやり直してください。');
        return;
      }

      _accept(values);
    } catch (error) {
      _message('写真の選択・QR解析に失敗しました：$error');
    } finally {
      if (mounted && !_closed && !_disposed) {
        setState(() => _photoBusy = false);
        _scheduleReconcile();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _scheduleReconcile();
  }

  Future<void> _release() async {
    try {
      await _backend.stop();
    } finally {
      await _backend.dispose();
    }
  }

  @override
  void dispose() {
    _markClosed();
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _route?.animation?.removeStatusListener(_animationChanged);
    _navigator?.userGestureInProgressNotifier.removeListener(
      _scheduleReconcile,
    );
    unawaited(_subscription?.cancel());
    _subscription = null;
    unawaited(
      _enqueue(_release).catchError((Object error) {
        debugPrint('[site-qr] camera release failed');
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope<String>(
    // iOSの戻るスワイプは維持する。
    canPop: true,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) return;
      _markClosed();
      _syncCamera();
    },
    child: Scaffold(
      appBar: AppBar(
        leading: BackButton(
          key: const ValueKey('site-qr-back'),
          onPressed: _back,
        ),
        title: const Text('サイト一式のQRを読む'),
        actions: [
          IconButton(
            key: const ValueKey('site-qr-photo'),
            tooltip: '写真から読み取る',
            onPressed: _photoBusy || _pending != null || _closed
                ? null
                : _readPhoto,
            icon: const Icon(Icons.photo_library_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                '「サイト一式のJSON・QR」で作成したQRを写してください。'
                '右上から写真も選べます。読み取りだけでは通信・保存しません。',
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_status, key: const ValueKey('site-qr-status')),
            ),
            if (_photoBusy) const LinearProgressIndicator(),
            TextButton(
              key: const ValueKey('site-qr-retry'),
              onPressed: _photoBusy || _pending != null || _closed
                  ? null
                  : () {
                      _message('カメラを再試行します。');
                      _syncCamera();
                    },
              child: const Text('カメラを再試行'),
            ),
            Expanded(child: _backend.preview()),
          ],
        ),
      ),
    ),
  );
}
