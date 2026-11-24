import 'package:flutter/material.dart';

import 'services/video_playback_speed.dart';

class VideoSpeedButton extends StatefulWidget {
  const VideoSpeedButton({
    super.key,
    required this.rate,
    required this.enabled,
    required this.onChanged,
  });

  final double rate;
  final bool enabled;
  final Future<void> Function(double rate) onChanged;

  @override
  State<VideoSpeedButton> createState() => _VideoSpeedButtonState();
}

class _VideoSpeedButtonState extends State<VideoSpeedButton> {
  bool _changing = false;

  Future<void> _select(double value) async {
    if (_changing || !widget.enabled || value == widget.rate) return;

    setState(() => _changing = true);

    try {
      await widget.onChanged(value);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('再生速度を変更できませんでした：$error')));
      }
    } finally {
      if (mounted) setState(() => _changing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_changing;
    final label = VideoPlaybackSpeed.label(widget.rate);

    return PopupMenuButton<double>(
      tooltip: '再生速度：$label',
      enabled: enabled,
      initialValue: widget.rate,
      onSelected: _select,
      itemBuilder: (_) => [
        for (final value in VideoPlaybackSpeed.values)
          CheckedPopupMenuItem<double>(
            value: value,
            checked: value == widget.rate,
            child: Text(
              value == 1
                  ? '${VideoPlaybackSpeed.label(value)}（標準）'
                  : VideoPlaybackSpeed.label(value),
            ),
          ),
      ],
      child: Semantics(
        button: true,
        enabled: enabled,
        label: '再生速度 $label',
        child: SizedBox(
          width: 56,
          height: 48,
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  key: const ValueKey('video-speed-current'),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 14,
                    color: enabled ? Colors.white : Colors.white38,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
