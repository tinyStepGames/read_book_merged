/// 表示後HTMLの作品一覧について、内容の安定を確認する。
///
/// 非同期取得の完了を保証するものではない。
/// サイトによっては待機時間やセレクターの調整が必要。
class RenderedListReadiness {
  RenderedListReadiness({
    this.minimumWait = const Duration(milliseconds: 1500),
    this.quietPeriod = const Duration(milliseconds: 900),
  });

  final Duration minimumWait;
  final Duration quietPeriod;

  Duration _startedAt = Duration.zero;
  Duration? _stableSince;
  String? _signature;

  void reset(Duration now) {
    _startedAt = now;
    _stableSince = null;
    _signature = null;
  }

  bool observe({
    required Duration now,
    required String ready,
    required int count,
    required String signature,
  }) {
    final documentReady = ready == 'interactive' || ready == 'complete';

    if (!documentReady || count <= 0 || signature.isEmpty) {
      _stableSince = null;
      _signature = null;
      return false;
    }

    if (_signature != signature) {
      _signature = signature;
      _stableSince = now;
      return false;
    }

    final stableSince = _stableSince;

    if (stableSince == null) {
      return false;
    }

    return now - _startedAt >= minimumWait && now - stableSince >= quietPeriod;
  }
}
