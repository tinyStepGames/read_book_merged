import 'dart:async';

/// 先読みを1件ずつ実行する。
///
/// updateで未着手の予約を置き換える。
/// 実行中の通信そのものは強制切断しない。
/// 失敗した画像は画面側の再試行に任せ、自動再試行を繰り返さない。
class ReaderLookAhead {
  ReaderLookAhead({required this.load});

  final Future<void> Function(int index) load;

  final Set<int> _attempted = <int>{};
  List<int> _pending = <int>[];
  bool _running = false;
  bool _disposed = false;

  void update(Iterable<int> indices) {
    if (_disposed) return;

    _pending = indices
        .where((index) => index >= 0 && !_attempted.contains(index))
        .toSet()
        .toList();

    if (!_running) {
      unawaited(_run());
    }
  }

  Future<void> _run() async {
    if (_running || _disposed) return;
    _running = true;

    try {
      while (!_disposed && _pending.isNotEmpty) {
        final index = _pending.removeAt(0);
        if (!_attempted.add(index)) continue;

        try {
          await load(index);
        } catch (_) {
          // 先読み失敗は画面の通常読み込み・再試行で回復する。
        }
      }
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _pending.clear();
  }
}
