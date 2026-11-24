import 'video_speed_button.dart';
import 'services/video_playback_speed.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'services/html_probe.dart';

/// 動画設定画面から明示的に開く再生テスト。
/// 履歴・再生位置・動画ファイルは保存しない。
class VideoPlaybackPage extends StatefulWidget {
  const VideoPlaybackPage({super.key, required this.url});

  final Uri url;

  @override
  State<VideoPlaybackPage> createState() => _VideoPlaybackPageState();
}

class _VideoPlaybackPageState extends State<VideoPlaybackPage> {
  Player? _player;
  VideoController? _controller;
  StreamSubscription<String>? _errors;
  bool _loading = true;
  double _rate = VideoPlaybackSpeed.rate;
  String? _error;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  void _fail(Object error) {
    if (!mounted) return;

    setState(() {
      _loading = false;
      _error =
          '動画を開けませんでした。\n'
          '配信元のアクセス条件・動画形式・通信状態を確認してください。\n'
          '$error';
    });
  }

  Future<void> _changeRate(double value) async {
    VideoPlaybackSpeed.validate(value);
    final player = _player;

    if (_loading || player == null) {
      throw StateError('動画の準備が完了していません');
    }

    await player.setRate(value).timeout(const Duration(seconds: 10));
    if (!mounted) return;

    VideoPlaybackSpeed.remember(value);
    setState(() => _rate = value);
  }

  Future<void> _prepare() async {
    try {
      final url = htmlProbeUri(widget.url.toString());

      MediaKit.ensureInitialized();

      final player = Player();
      _player = player;
      _errors = player.stream.error.listen(_fail, onError: _fail);
      _controller = VideoController(player);

      // 自動再生しない。利用者がプレーヤーの再生を押す。
      await player
          .open(Media(url.toString()), play: false)
          .timeout(const Duration(seconds: 40));

      if (!mounted) return;

      final playbackRate = VideoPlaybackSpeed.rate;
      await player.setRate(playbackRate).timeout(const Duration(seconds: 10));

      if (!mounted) return;
      setState(() {
        _rate = playbackRate;
        _loading = false;
      });
    } catch (error) {
      _fail(error);
    }
  }

  Future<void> _release() async {
    try {
      await _errors?.cancel();
      await _player?.dispose();
    } catch (error) {
      debugPrint('[video-preview] dispose_failed=$error');
    }
  }

  @override
  void dispose() {
    unawaited(_release());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('動画再生テスト'),
        actions: [
          VideoSpeedButton(
            rate: _rate,
            enabled: !_loading && _player != null,
            onChanged: _changeRate,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                _error!,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (controller != null)
                  AbsorbPointer(
                    absorbing: _loading,
                    child: Video(controller: controller),
                  ),
                if (_loading) const Center(child: CircularProgressIndicator()),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
