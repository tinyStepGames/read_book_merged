import 'package:flutter/material.dart';

/// 操作パネルの既存行に収める画像番号表示。
/// 高さを固定し、番号が長い場合は縮小して行の高さを増やさない。
class ReaderPageCounter extends StatelessWidget {
  const ReaderPageCounter({
    super.key,
    required this.current,
    required this.total,
  });

  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    if (total <= 0) return const SizedBox.shrink();

    final page = current.clamp(1, total);

    return Semantics(
      label: '全$total枚中$page枚目',
      child: ExcludeSemantics(
        child: SizedBox(
          height: 20,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              '$page / $total',
              key: const ValueKey('reader-page-counter-text'),
              maxLines: 1,
              softWrap: false,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
