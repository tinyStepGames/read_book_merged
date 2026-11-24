import 'services/site_video_browser_error.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'services/site_video_browser_policy.dart';

class SiteVideoBrowserButton extends StatelessWidget {
  const SiteVideoBrowserButton({
    super.key,
    required this.onPressed,
    this.compact = false,
  });

  final VoidCallback? onPressed;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return IconButton(
        tooltip: 'サイトプレーヤーで開く',
        onPressed: onPressed,
        icon: const Icon(Icons.public),
      );
    }

    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.public),
      label: const Text('サイトプレーヤーで開く'),
    );
  }
}

class _SiteVideoWebViewEnvironment {
  static Future<WebViewEnvironment>? _future;

  static Future<WebViewEnvironment> get() => _future ??= _create();

  static Future<WebViewEnvironment> _create() async {
    try {
      final version = await WebViewEnvironment.getAvailableVersion();
      if (version == null) {
        throw StateError('Microsoft Edge WebView2 Runtimeが必要です');
      }

      final support = await getApplicationSupportDirectory();

      return await WebViewEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: p.join(support.path, 'video-site-player-webview-v1'),
        ),
      );
    } catch (_) {
      _future = null;
      rethrow;
    }
  }
}

class SiteVideoBrowserPage extends StatefulWidget {
  const SiteVideoBrowserPage({
    super.key,
    required this.url,
    required this.title,
  });

  final String url;
  final String title;

  @override
  State<SiteVideoBrowserPage> createState() => _SiteVideoBrowserPageState();
}

class _SiteVideoBrowserPageState extends State<SiteVideoBrowserPage> {
  SiteVideoBrowserPolicy? _policy;
  InAppWebViewController? _controller;
  WebViewEnvironment? _environment;

  bool _preparing = false;
  bool _prepared = false;
  bool _fullscreen = false;
  bool _popupNoticeShown = false;
  bool _mainDocumentLoaded = false;
  final _blockedMainFrameUrls = <String>{};
  int _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();

    try {
      _policy = SiteVideoBrowserPolicy(widget.url);
    } catch (error) {
      _error = '掲載ページのURLを確認できませんでした：$error';
    }
  }

  void _notice(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _prepare() async {
    if (_preparing || _prepared || _policy == null) return;

    setState(() {
      _preparing = true;
      _error = null;
    });

    try {
      WebViewEnvironment? environment;

      if (Platform.isWindows) {
        environment = await _SiteVideoWebViewEnvironment.get();
      }

      if (!mounted) return;

      setState(() {
        _environment = environment;
        _prepared = true;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'ブラウザーを準備できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  Future<void> _backInPage() async {
    final controller = _controller;
    if (controller == null) return;

    try {
      if (await controller.canGoBack()) {
        await controller.goBack();
      } else {
        _notice('これより前のページはありません。');
      }
    } catch (error) {
      _notice('ページを戻せませんでした：$error');
    }
  }

  Future<void> _reload() async {
    final controller = _controller;
    if (controller == null) return;

    try {
      if (mounted) setState(() => _error = null);
      await controller.reload();
    } catch (error) {
      _notice('再読み込みできませんでした：$error');
    }
  }

  Future<void> _home() async {
    final controller = _controller;
    final policy = _policy;
    if (controller == null || policy == null) return;

    try {
      if (mounted) setState(() => _error = null);

      await controller.loadUrl(
        urlRequest: URLRequest(url: WebUri(policy.initial.toString())),
      );
    } catch (error) {
      _notice('掲載ページを開き直せませんでした：$error');
    }
  }

  Future<void> _copyUrl() async {
    final policy = _policy;
    if (policy == null) return;

    try {
      await Clipboard.setData(ClipboardData(text: policy.initial.toString()));
      _notice('掲載ページのURLをコピーしました。必要ならEdge等で開いてください。');
    } catch (error) {
      _notice('URLをコピーできませんでした：$error');
    }
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('サイトプレーヤー再生'),
        content: const SingleChildScrollView(
          child: Text(
            '掲載ページ上でMoonなどのサーバーを選び、再生を押してください。\n\n'
            'この画面ではサイト側の再生・倍速・全画面操作を使用します。\n'
            'アプリ側の動画保存・再生位置保存・再生履歴の自動記録は行いません。\n\n'
            '別ウィンドウやポップアップは作成しません。'
            '別サイトへの画面全体の移動も制限します。'
            '埋め込みプレーヤーなどの外部HTTPSコンテンツは読み込まれます。\n\n'
            'ポップアップが必須のサイトや、WebView非対応の動画は'
            '動作しない場合があります。'
            '必要ならURLをコピーして外部ブラウザーで開いてください。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  Widget _consent() {
    final policy = _policy;

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              if (policy != null) SelectableText(policy.initial.toString()),
              const SizedBox(height: 20),
              const Text(
                'この話の掲載ページをアプリ内ブラウザーで表示します。\n'
                'ページ上でMoonなどの再生サーバーを選択してください。\n\n'
                '掲載ページや埋め込み先のJavaScript・Cookie等を使用します。'
                '要素検査・画像取得とは別のWebView領域を使用します。\n\n'
                'ここではアプリ側のダウンロード・倍速・再生位置保存は行いません。'
                'サイト側の操作機能を使用します。',
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                SelectableText(
                  _error!,
                  style: const TextStyle(color: Colors.orangeAccent),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: policy == null || _preparing ? null : _prepare,
                icon: const Icon(Icons.public),
                label: Text(_preparing ? '準備中…' : '掲載ページを表示する'),
              ),
              if (_preparing) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _browser() {
    final policy = _policy!;

    return Stack(
      fit: StackFit.expand,
      children: [
        InAppWebView(
          key: const ValueKey('site-video-browser-webview'),
          webViewEnvironment: _environment,
          initialUrlRequest: URLRequest(url: WebUri(policy.initial.toString())),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            useShouldOverrideUrlLoading: true,
            mediaPlaybackRequiresUserGesture: true,
            allowsInlineMediaPlayback: true,
            javaScriptCanOpenWindowsAutomatically: false,
            supportMultipleWindows: true,
            allowFileAccessFromFileURLs: false,
            allowUniversalAccessFromFileURLs: false,
            useOnDownloadStart: true,
            incognito: true,
          ),
          onWebViewCreated: (controller) {
            _controller = controller;
            // 外部ページ用の独自JavaScriptハンドラーは登録しない。
          },
          shouldOverrideUrlLoading: (controller, action) async {
            final value = action.request.url?.toString();
            if (value == null) return NavigationActionPolicy.CANCEL;

            if (action.isForMainFrame) {
              if (!policy.allowsMainFrame(value)) {
                if (_blockedMainFrameUrls.length >= 32) {
                  _blockedMainFrameUrls.clear();
                }
                _blockedMainFrameUrls.add(value);
                debugPrint('[site-video-browser] main navigation blocked');
                return NavigationActionPolicy.CANCEL;
              }
            } else if (!policy.allowsSubframe(value)) {
              return NavigationActionPolicy.CANCEL;
            }

            return NavigationActionPolicy.ALLOW;
          },
          onCreateWindow: (controller, action) async {
            if (!_popupNoticeShown) {
              _popupNoticeShown = true;
              debugPrint('[site-video-browser] popup blocked');
            }
            return false;
          },
          onPermissionRequest: (controller, request) async =>
              PermissionResponse(
                resources: request.resources,
                action: PermissionResponseAction.DENY,
              ),
          onDownloadStartRequest: (controller, request) async {
            _notice('この画面からのファイル保存には対応していません。');
          },
          onLoadStart: (controller, url) {
            if (!mounted) return;
            setState(() {
              _progress = 0;
              _mainDocumentLoaded = false;
              _error = null;
            });
          },
          onLoadStop: (controller, url) async {
            if (!mounted || url == null) return;
            if (policy.allowsMainFrame(url.toString()) && _error == null) {
              _mainDocumentLoaded = true;
            }
          },
          onProgressChanged: (controller, progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onReceivedError: (controller, request, error) {
            if (!mounted) return;

            final requestUrl = request.url.toString();
            final blocked = _blockedMainFrameUrls.remove(requestUrl);
            final show = showSiteVideoBrowserLoadError(
              mainFrame: request.isForMainFrame == true,
              connectionAborted:
                  error.type == WebResourceErrorType.CONNECTION_ABORTED,
              pageLoaded: _mainDocumentLoaded,
              explicitlyBlocked: blocked,
            );

            if (!show) {
              debugPrint(
                '[site-video-browser] non-fatal load event: '
                '${error.type} ${error.description}',
              );
              return;
            }

            setState(() {
              _error = 'ページを読み込めませんでした：${error.description}';
            });
          },
          onReceivedHttpError: (controller, request, response) {
            if (request.isForMainFrame == true && mounted) {
              setState(() {
                _error =
                    '掲載ページの取得に失敗しました：'
                    'HTTP ${response.statusCode}';
              });
            }
          },
          onEnterFullscreen: (controller) {
            if (mounted) setState(() => _fullscreen = true);
          },
          onExitFullscreen: (controller) {
            if (mounted) setState(() => _fullscreen = false);
          },
        ),
        if (_progress < 100)
          Align(
            alignment: Alignment.topCenter,
            child: LinearProgressIndicator(value: _progress / 100),
          ),
        if (_error != null)
          Align(
            alignment: Alignment.bottomCenter,
            child: Material(
              color: Colors.black87,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: Colors.orangeAccent),
                      ),
                    ),
                    IconButton(
                      tooltip: '案内を閉じる',
                      onPressed: () => setState(() => _error = null),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: _fullscreen
        ? null
        : AppBar(
            title: Text(
              'サイト再生：${widget.title}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: [
              if (_prepared) ...[
                IconButton(
                  tooltip: 'ページ内で戻る',
                  onPressed: _backInPage,
                  icon: const Icon(Icons.arrow_back),
                ),
                IconButton(
                  tooltip: 'この話の掲載ページへ戻る',
                  onPressed: _home,
                  icon: const Icon(Icons.home_outlined),
                ),
                IconButton(
                  tooltip: '再読み込み',
                  onPressed: _reload,
                  icon: const Icon(Icons.refresh),
                ),
              ],
              IconButton(
                tooltip: '掲載ページのURLをコピー',
                onPressed: _policy == null ? null : _copyUrl,
                icon: const Icon(Icons.copy),
              ),
              IconButton(
                tooltip: 'この再生方式について',
                onPressed: _showHelp,
                icon: const Icon(Icons.info_outline),
              ),
            ],
          ),
    body: SafeArea(
      top: !_fullscreen,
      bottom: !_fullscreen,
      child: _prepared ? _browser() : _consent(),
    ),
  );
}
