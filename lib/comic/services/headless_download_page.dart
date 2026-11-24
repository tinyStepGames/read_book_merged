import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'html_probe.dart';
import 'rendered_list_readiness.dart';
import 'rendered_rule_capture.dart';

/// ダウンロード専用。Navigatorや画面のBuildContextを使用しない。
Future<HtmlProbePage> fetchRenderedDownloadPage(
  String input, {
  required CancelToken cancelToken,
  required String allowedOrigin,
  required String groupSelector,
  bool fastForLists = false,
}) async {
  if (cancelToken.isCancelled) {
    throw StateError('保存を中断しました');
  }

  final target = htmlProbeUri(input);

  if (target.origin != allowedOrigin) {
    throw const FormatException('取得元が一致しません');
  }

  if (groupSelector.trim().isEmpty || groupSelector.length > 8192) {
    throw const FormatException('本文画像のセレクターが不正です');
  }

  final abort = Completer<void>();
  Object? abortReason;
  var finished = false;

  void stop(Object reason) {
    if (finished || abort.isCompleted) return;
    abortReason = reason;
    abort.complete();
  }

  final deadline = Timer(
    const Duration(seconds: 40),
    () => stop(
      StateError(
        '画面を開かない取得が時間切れになりました。'
        'ページ上の操作が必要なサイトは、取得ルールを確認してください。',
      ),
    ),
  );

  unawaited(
    cancelToken.whenCancel.then((_) {
      stop(StateError('保存を中断しました'));
    }),
  );

  Future<T> guarded<T>(Future<T> operation) async {
    if (abort.isCompleted) {
      throw abortReason ?? StateError('取得を中止しました');
    }

    final result = await Future.any<T>([
      operation,
      abort.future.then<T>((_) {
        throw abortReason ?? StateError('取得を中止しました');
      }),
    ]);

    if (abort.isCompleted) {
      throw abortReason ?? StateError('取得を中止しました');
    }
    return result;
  }

  HeadlessInAppWebView? webView;

  final totalClock = Stopwatch()..start();
  int? environmentMs;
  int? controllerMs;
  int? firstMatchMs;
  int? captureMs;

  try {
    WebViewEnvironment? environment;

    if (Platform.isWindows) {
      // Windows用の環境はアプリ起動中に再利用する。
      environment = await guarded(_DownloadWebViewEnvironment.get());
    }

    environmentMs = totalClock.elapsedMilliseconds;

    final created = Completer<InAppWebViewController>();
    var navigationGeneration = 0;

    bool allowed(WebUri? value) {
      if (value == null) return false;

      final uri = Uri.tryParse(value.toString());
      return uri != null &&
          uri.scheme == 'https' &&
          uri.userInfo.isEmpty &&
          uri.origin == allowedOrigin;
    }

    webView = HeadlessInAppWebView(
      webViewEnvironment: environment,
      initialSize: const Size(1024, 768),
      initialUrlRequest: URLRequest(url: WebUri(target.toString())),
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
        if (!created.isCompleted) created.complete(controller);
      },
      shouldOverrideUrlLoading: (controller, action) async {
        return allowed(action.request.url)
            ? NavigationActionPolicy.ALLOW
            : NavigationActionPolicy.CANCEL;
      },
      onCreateWindow: (controller, action) async => false,
      onPermissionRequest: (controller, request) async {
        return PermissionResponse(
          resources: request.resources,
          action: PermissionResponseAction.DENY,
        );
      },
      onLoadStart: (controller, url) {
        navigationGeneration++;
        if (url != null && !allowed(url)) {
          stop(const FormatException('別の取得元への移動を中止しました'));
        }
      },
      onReceivedError: (controller, request, error) {
        if (request.isForMainFrame == true) {
          stop(StateError('本文ページの読み込みに失敗しました：${error.description}'));
        }
      },
      onReceivedHttpError: (controller, request, response) {
        if (request.isForMainFrame == true) {
          stop(StateError('本文ページの取得に失敗しました：HTTP ${response.statusCode}'));
        }
      },
    );

    await guarded(webView.run());
    final controller = await guarded(created.future);

    controllerMs = totalClock.elapsedMilliseconds - environmentMs;

    final selector = jsonEncode(groupSelector);
    final clock = Stopwatch()..start();
    final listReadiness = RenderedListReadiness();
    var previousNavigationGeneration = navigationGeneration;
    String? previousSignature;
    Duration? stableSince;

    // 一覧内の属性・テキストの変更を検出する。
    // HTMLサイズが同じまま内容が変わった場合も判定対象にする。
    // 一覧のHTMLそのものは毎回Dartへ送らない。
    const listFingerprintScript = r'''
function ocrListFingerprint(nodes) {
  let hash1 = 2166136261;
  let hash2 = 5381;
  let length = 0;

  function feed(text) {
    length += text.length;

    for (let i = 0; i < text.length; i++) {
      const code = text.charCodeAt(i);
      hash1 = Math.imul(hash1 ^ code, 16777619);
      hash2 = Math.imul(hash2, 33) ^ code;
    }
  }

  for (let i = 0; i < nodes.length; i++) {
    feed(String(i));
    feed(':');
    feed(nodes[i].outerHTML);
    feed('\n');
  }

  return nodes.length + ':' + length + ':' +
    (hash1 >>> 0) + ':' + (hash2 >>> 0);
}
''';

    while (true) {
      if (cancelToken.isCancelled) {
        throw StateError('保存を中断しました');
      }

      if (previousNavigationGeneration != navigationGeneration) {
        previousNavigationGeneration = navigationGeneration;
        previousSignature = null;
        stableSince = null;
        listReadiness.reset(clock.elapsed);
      }

      final generation = navigationGeneration;

      final raw = await guarded(
        controller.evaluateJavascript(
          source:
              '''
(() => {
  const root = document.documentElement;
  const nodes = document.querySelectorAll($selector);
  const count = nodes.length;
  const fast = $fastForLists;

  $listFingerprintScript

  // 通常モードは従来どおりページ全体のサイズを監視する。
  // 高速一覧モードでは対象一覧の内容を監視する。
  // 最終HTMLのサイズ制限は、取得時に別途確認する。
  const size = !fast && root ? root.outerHTML.length : 0;

  if (size > 2097152) {
    throw new Error('表示後HTMLが大きすぎます');
  }

  return JSON.stringify({
    url: location.href,
    ready: document.readyState,
    count,
    size,
    fingerprint: fast ? ocrListFingerprint(nodes) : ''
  });
})()
''',
        ),
      );

      if (generation != navigationGeneration) {
        previousSignature = null;
        stableSince = null;
      } else if (raw is String && raw.length <= 16000) {
        final data = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final pageUri = htmlProbeUri(data['url'] as String);

        if (pageUri.origin != allowedOrigin) {
          throw const FormatException('設定した取得元とは異なるページです');
        }

        final count = data['count'] as int;
        final signature = fastForLists
            ? '${data['url']}|${data['fingerprint']}'
            : '${data['url']}|$count|${data['size']}';
        final now = clock.elapsed;

        if (count > 0) {
          firstMatchMs ??= totalClock.elapsedMilliseconds;
        }

        var shouldCapture = false;

        if (fastForLists) {
          shouldCapture = listReadiness.observe(
            now: now,
            ready: data['ready'] as String,
            count: count,
            signature: signature,
          );
        } else if (data['ready'] != 'complete' || count == 0) {
          previousSignature = null;
          stableSince = null;
        } else if (previousSignature != signature) {
          previousSignature = signature;
          stableSince = now;
        } else if (stableSince != null &&
            now - stableSince >= const Duration(seconds: 2)) {
          shouldCapture = true;
        }

        if (shouldCapture) {
          final captureClock = Stopwatch()..start();
          final captured = await guarded(
            controller.evaluateJavascript(
              source:
                  '''
(() => {
  const root = document.documentElement;
  if (!root || !document.querySelector($selector)) {
    throw new Error('本文画像が見つかりません');
  }

  const source = root.outerHTML;
  if (source.length > 2097152) {
    throw new Error('表示後HTMLが大きすぎます');
  }

  $listFingerprintScript

  return JSON.stringify({
    url: location.href,
    source,
    fingerprint: $fastForLists
      ? ocrListFingerprint(document.querySelectorAll($selector))
      : ''
  });
})()
''',
            ),
          );

          if (generation != navigationGeneration) {
            previousSignature = null;
            stableSince = null;
          } else {
            if (captured is! String) {
              throw const FormatException('表示後HTMLを取得できませんでした');
            }

            var unchanged = true;

            if (fastForLists) {
              final capturedData = Map<String, dynamic>.from(
                jsonDecode(captured) as Map,
              );

              unchanged =
                  capturedData['url'] == data['url'] &&
                  capturedData['fingerprint'] == data['fingerprint'];

              if (!unchanged) {
                listReadiness.reset(clock.elapsed);
              }
            }

            if (unchanged) {
              captureMs = captureClock.elapsedMilliseconds;

              return decodeRenderedRulePage(
                captured,
                allowedOrigin: allowedOrigin,
              );
            }
          }
        }
      }

      await guarded(
        Future<void>.delayed(Duration(milliseconds: fastForLists ? 200 : 500)),
      );
    }
  } finally {
    finished = true;
    deadline.cancel();

    // 成功・失敗・中断のどの場合も、作成した非表示WebViewを破棄する。
    final disposeClock = Stopwatch()..start();
    final targetWebView = webView;
    if (targetWebView != null) {
      try {
        await targetWebView.dispose().timeout(const Duration(seconds: 5));
      } catch (_) {
        // 破棄時のエラーで本来の取得結果を上書きしない。
      }
    }

    if (fastForLists) {
      assert(() {
        debugPrint(
          '[rendered-list] '
          'environment=${environmentMs ?? -1}ms '
          'controller=${controllerMs ?? -1}ms '
          'first_match=${firstMatchMs ?? -1}ms '
          'capture=${captureMs ?? -1}ms '
          'dispose=${disposeClock.elapsedMilliseconds}ms '
          'total=${totalClock.elapsedMilliseconds}ms',
        );
        return true;
      }());
    }
  }
}

/// 既存の目視確認用WebViewとは保存領域を分離する。
class _DownloadWebViewEnvironment {
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
          userDataFolder: p.join(
            support.path,
            'rule-download-headless-webview',
          ),
        ),
      );
    } catch (_) {
      _future = null;
      rethrow;
    }
  }
}
