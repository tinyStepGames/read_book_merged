import 'package:flutter/material.dart';

class ReaderNetworkImage extends StatefulWidget {
  const ReaderNetworkImage({
    super.key,
    required this.provider,
    this.width,
    this.fit = BoxFit.contain,
    this.onReady,
  });

  final ImageProvider<Object> provider;
  final double? width;
  final BoxFit fit;
  final VoidCallback? onReady;

  @override
  State<ReaderNetworkImage> createState() => _ReaderNetworkImageState();
}

class _ReaderNetworkImageState extends State<ReaderNetworkImage> {
  bool _notified = false;
  bool _retrying = false;
  int _revision = 0;

  @override
  void didUpdateWidget(covariant ReaderNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.provider != widget.provider) {
      _notified = false;
      _revision++;
    }
  }

  void _notifyReady() {
    if (_notified) return;
    _notified = true;
    final revision = _revision;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || revision != _revision) return;
      widget.onReady?.call();
    });
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);

    try {
      await widget.provider.evict();
    } catch (_) {
      // 破棄できなかった場合もImageを作り直して再評価する。
    }

    if (!mounted) return;

    setState(() {
      _retrying = false;
      _notified = false;
      _revision++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Image(
      key: ValueKey(_revision),
      image: widget.provider,
      width: widget.width,
      fit: widget.fit,
      frameBuilder: (context, child, frame, synchronouslyLoaded) {
        if (synchronouslyLoaded || frame != null) {
          _notifyReady();
          return child;
        }

        // 読み込み中は本文上に文字やスピナーを重ねない。
        return SizedBox(
          width: widget.width,
          height: 240,
          child: const ColoredBox(color: Colors.black),
        );
      },
      errorBuilder: (context, error, stack) {
        return SizedBox(
          width: widget.width,
          height: 240,
          child: ColoredBox(
            color: Colors.black,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '画像を読み込めませんでした',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _retrying ? null : _retry,
                    icon: const Icon(Icons.refresh),
                    label: Text(_retrying ? '再試行中…' : '再試行'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
