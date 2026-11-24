import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// 横読み用のページ送り。
///
/// 左1/3: 前へ
/// 中央1/3: 操作表示の切り替え
/// 右1/3: 次へ
/// ダブルタップ: 拡大
///
/// 横ドラッグはPageViewに任せ、タップ用の透明な覆いを重ねない。
class ReaderHorizontalPager extends StatelessWidget {
  const ReaderHorizontalPager({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.onPageChanged,
    required this.onToggleControls,
    required this.onZoom,
    required this.imageBuilder,
    this.onPrevious,
    this.onNext,
  });

  final PageController controller;
  final int itemCount;
  final ValueChanged<int> onPageChanged;
  final VoidCallback onToggleControls;
  final ValueChanged<int> onZoom;
  final IndexedWidgetBuilder imageBuilder;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final behavior = ScrollConfiguration.of(context).copyWith(
      dragDevices: {
        PointerDeviceKind.touch,
        PointerDeviceKind.mouse,
        PointerDeviceKind.stylus,
        PointerDeviceKind.invertedStylus,
        PointerDeviceKind.trackpad,
      },
    );

    return ScrollConfiguration(
      behavior: behavior,
      child: PageView.builder(
        controller: controller,
        scrollDirection: Axis.horizontal,
        physics: const PageScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        itemCount: itemCount,
        onPageChanged: onPageChanged,
        itemBuilder: (context, index) {
          return LayoutBuilder(
            builder: (context, constraints) {
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final width = constraints.maxWidth;
                  if (!width.isFinite || width <= 0) return;

                  final x = details.localPosition.dx;

                  if (x < width / 3) {
                    onPrevious?.call();
                  } else if (x > width * 2 / 3) {
                    onNext?.call();
                  } else {
                    onToggleControls();
                  }
                },
                onDoubleTap: () => onZoom(index),
                child: SizedBox.expand(
                  child: Center(child: imageBuilder(context, index)),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
