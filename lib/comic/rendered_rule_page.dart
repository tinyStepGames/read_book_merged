import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'services/html_probe.dart';
import 'services/rendered_rule_capture.dart';

class RenderedRulePage extends StatefulWidget {
  const RenderedRulePage({
    super.key,
    required this.url,
    required this.allowedOrigin,
    required this.groupSelector,
    required this.cancelToken,
    this.backgroundMode = false,
    this.silentMode = false,
    this.previewTitle = '',
    this.previewThumbnail,
  });

  final String url;
  final String allowedOrigin;
  final String groupSelector;
  final CancelToken cancelToken;
  final bool backgroundMode;
  final bool silentMode;
  final String previewTitle;
  final Uri? previewThumbnail;

  @override
  State<RenderedRulePage> createState() => _RenderedRulePageState();
}

class _RenderedRulePageState extends State<RenderedRulePage> {
  InAppWebViewController? _controller;
  WebViewEnvironment? _environment;
  Timer? _timer;
  Uri? _initial;
  bool _prepared = false;
  bool _showBrowser = false;
  bool _silentControls = false;
  bool _polling = false;
  bool _capturing = false;
  bool _finished = false;
  bool _auto = true;
  int _generation = 0;
  int _count = 0;
  String? _signature;
  DateTime? _stableSince;
  DateTime _started = DateTime.now();
  String _status = 'ページ表示を準備中';

  @override
  void initState() {
    super.initState();
    _prepare();

    widget.cancelToken.whenCancel.then((_) {
      if (!mounted || _finished) return;

      // 先に終了扱いにし、取得完了側との二重終了を防ぐ。
      _finished = true;
      _timer?.cancel();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ModalRoute.of(context)?.isCurrent != true) return;
        Navigator.of(context).pop();
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    });
  }

  Future<void> _prepare() async {
    try {
      _initial = htmlProbeUri(widget.url);
      if (_initial!.origin != widget.allowedOrigin) {
        throw const FormatException('取得元が一致しません');
      }

      if (Platform.isWindows) {
        final version = await WebViewEnvironment.getAvailableVersion();
        if (version == null) {
          throw StateError('Microsoft Edge WebView2 Runtimeが必要です');
        }

        final support = await getApplicationSupportDirectory();
        _environment = await WebViewEnvironment.create(
          settings: WebViewEnvironmentSettings(
            userDataFolder: p.join(support.path, 'rule-inspector-webview'),
          ),
        );
      }

      if (!mounted || _finished) return;
      setState(() {
        _prepared = true;
        _status = '読み込み中';
        _started = DateTime.now();
      });
    } catch (error) {
      if (mounted && !_finished) {
        setState(() => _status = '準備できませんでした：$error');
      }
    }
  }

  void _resetWaiting() {
    _signature = null;
    _stableSince = null;
    _count = 0;
    _started = DateTime.now();
  }

  bool _allowed(Uri? uri) =>
      uri != null &&
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      uri.origin == widget.allowedOrigin;

  Future<void> _poll() async {
    final controller = _controller;
    if (!mounted ||
        controller == null ||
        _finished ||
        _polling ||
        _capturing ||
        widget.cancelToken.isCancelled) {
      return;
    }

    _polling = true;
    final generation = _generation;

    try {
      final selector = jsonEncode(widget.groupSelector);
      final raw = await controller.evaluateJavascript(
        source:
            '''
(() => {
  const root = document.documentElement;
  return JSON.stringify({
    url: location.href,
    ready: document.readyState,
    count: document.querySelectorAll($selector).length,
    size: root ? root.outerHTML.length : 0
  });
})()
''',
      );

      if (!mounted || _finished || generation != _generation) return;
      if (raw is! String || raw.length > 16000) return;

      final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final uri = htmlProbeUri(data['url'] as String);
      if (!_allowed(uri)) {
        throw const FormatException('設定した取得元とは異なるページです');
      }

      final count = data['count'] as int;
      final now = DateTime.now();
      final signature = '${data['url']}|$count|${data['size']}';
      _count = count;

      if (data['ready'] != 'complete' || count == 0) {
        _signature = null;
        _stableSince = null;
      } else if (_signature != signature) {
        _signature = signature;
        _stableSince = now;
      }

      if (_auto &&
          _stableSince != null &&
          now.difference(_stableSince!) >= const Duration(seconds: 2)) {
        await _capture();
        return;
      }

      if (_auto && now.difference(_started) > const Duration(seconds: 30)) {
        setState(() {
          _auto = false;
          _status =
              '自動待機の上限に達しました。'
              '必要なボタンを操作し、一覧を確認してから取得してください。'
              ' 現在$count件一致';
        });
        return;
      }

      setState(() {
        _status = _auto
            ? '$count件一致／一覧の安定を待っています'
            : '$count件一致／表示を確認して「このページから取得」を押してください';
      });
    } catch (error) {
      if (mounted && !_finished && generation == _generation) {
        setState(() {
          _auto = false;
          _status = '一覧を確認できませんでした：$error';
        });
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null ||
        _capturing ||
        _finished ||
        widget.cancelToken.isCancelled) {
      return;
    }

    final generation = _generation;
    setState(() => _capturing = true);

    try {
      final selector = jsonEncode(widget.groupSelector);
      final raw = await controller.evaluateJavascript(
        source:
            '''
(() => {
  if (!document.querySelector($selector)) {
    throw new Error('一覧のまとまりが見つかりません');
  }
  const source = document.documentElement.outerHTML;
  if (source.length > 2097152) {
    throw new Error('表示後HTMLが大きすぎます');
  }
  return JSON.stringify({url: location.href, source});
})()
''',
      );

      if (!mounted ||
          _finished ||
          generation != _generation ||
          widget.cancelToken.isCancelled) {
        return;
      }
      if (raw is! String) {
        throw const FormatException('表示後HTMLを取得できませんでした');
      }

      final page = decodeRenderedRulePage(
        raw,
        allowedOrigin: widget.allowedOrigin,
      );

      _finished = true;
      _timer?.cancel();

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ModalRoute.of(context)?.isCurrent != true) return;

        // 完了後、画面を閉じるまでにキャンセルされた場合は結果を返さない。
        Navigator.of(context).pop(widget.cancelToken.isCancelled ? null : page);
      });
      WidgetsBinding.instance.ensureVisualUpdate();
    } catch (error) {
      if (mounted && !_finished) {
        setState(() {
          _auto = false;
          _status = '取得できませんでした：$error';
        });
      }
    } finally {
      if (mounted && !_finished) {
        setState(() => _capturing = false);
      }
    }
  }

  @override
  void dispose() {
    _finished = true;
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.silentMode && !_showBrowser) {
      final failedPreparation = _status.startsWith('準備できませんでした');
      final waiting = (_auto || _capturing) && !failedPreparation;

      return Stack(
        fit: StackFit.expand,
        children: [
          // 隠している間もWebViewを動かしてHTMLを取得する。
          _buildBrowser(context),
          Positioned.fill(
            child: Scaffold(
              backgroundColor: Colors.black,
              body: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  setState(() => _silentControls = !_silentControls);
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Colors.black),
                    if (_silentControls || !waiting)
                      const SafeArea(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: BackButton(color: Colors.white),
                        ),
                      ),
                    if (!waiting)
                      Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _status,
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white70),
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed: () {
                                  setState(() => _showBrowser = true);
                                },
                                icon: const Icon(Icons.open_in_browser),
                                label: const Text('ページを表示して操作'),
                              ),
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _auto = true;
                                    _resetWaiting();
                                  });
                                },
                                child: const Text('自動取得を再試行'),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        _buildBrowser(context),
        if (widget.backgroundMode && !_showBrowser)
          Positioned.fill(
            child: Scaffold(
              backgroundColor: Colors.black,
              appBar: AppBar(
                title: Text(
                  widget.previewTitle.isEmpty
                      ? '一覧を読み込み中'
                      : widget.previewTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              body: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.previewThumbnail != null) ...[
                        Center(
                          child: SizedBox(
                            width: 220,
                            height: 320,
                            child: Image.network(
                              widget.previewThumbnail.toString(),
                              fit: BoxFit.contain,
                              cacheWidth: 660,
                              errorBuilder: (_, error, stack) => const Center(
                                child: Icon(
                                  Icons.broken_image_outlined,
                                  size: 48,
                                  color: Colors.white38,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (widget.previewTitle.isNotEmpty) ...[
                        Text(
                          widget.previewTitle,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 20),
                      ],
                      if (_auto || _capturing) ...[
                        const LinearProgressIndicator(),
                        const SizedBox(height: 12),
                        const Text(
                          '一覧を読み込んでいます…',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ] else ...[
                        Text(
                          _status,
                          style: const TextStyle(color: Colors.white70),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'ページ上の操作が必要な場合は、下のボタンから表示できます。',
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: _capturing
                              ? null
                              : () => setState(() => _showBrowser = true),
                          icon: const Icon(Icons.open_in_browser),
                          label: const Text('ページを表示して操作'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildBrowser(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(title: const Text('ページを表示して一覧を取得')),
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_status),
                const SizedBox(height: 6),
                const Text(
                  '自動取得は件数・HTMLサイズの安定で判断します。'
                  'ボタン操作が必要なら自動取得をOFFにしてください。',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('一覧が安定したら自動取得'),
                  value: _auto,
                  onChanged: _capturing
                      ? null
                      : (value) => setState(() {
                          _auto = value;
                          _resetWaiting();
                        }),
                ),
                FilledButton.icon(
                  onPressed: _controller == null || _capturing || _count == 0
                      ? null
                      : _capture,
                  icon: const Icon(Icons.download_outlined),
                  label: Text(_capturing ? '取得中…' : 'このページから取得'),
                ),
              ],
            ),
          ),
          Expanded(
            child: !_prepared
                ? const Center(child: Text('準備完了後にページを表示します'))
                : InAppWebView(
                    webViewEnvironment: _environment,
                    initialUrlRequest: URLRequest(
                      url: WebUri(_initial.toString()),
                    ),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      useShouldOverrideUrlLoading: true,
                      mediaPlaybackRequiresUserGesture: true,
                      javaScriptCanOpenWindowsAutomatically: false,
                      supportMultipleWindows: true,
                      allowFileAccessFromFileURLs: false,
                      allowUniversalAccessFromFileURLs: false,
                      incognito: true,
                    ),
                    onWebViewCreated: (controller) {
                      _controller = controller;
                      _timer = Timer.periodic(
                        const Duration(milliseconds: 500),
                        (_) => _poll(),
                      );
                    },
                    shouldOverrideUrlLoading: (controller, action) async {
                      final url = action.request.url;
                      final uri = url == null
                          ? null
                          : Uri.tryParse(url.toString());

                      return _allowed(uri)
                          ? NavigationActionPolicy.ALLOW
                          : NavigationActionPolicy.CANCEL;
                    },
                    onCreateWindow: (controller, action) async => false,
                    onPermissionRequest: (controller, request) async =>
                        PermissionResponse(
                          resources: request.resources,
                          action: PermissionResponseAction.DENY,
                        ),
                    onLoadStart: (controller, url) {
                      if (!mounted || _finished) return;
                      setState(() {
                        _generation++;
                        _resetWaiting();
                        _status = 'ページを読み込み中';
                      });
                    },
                    onReceivedError: (controller, request, error) {
                      if (request.isForMainFrame == true &&
                          mounted &&
                          !_finished) {
                        setState(() {
                          _auto = false;
                          _status = '読み込みエラー：${error.description}';
                        });
                      }
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
