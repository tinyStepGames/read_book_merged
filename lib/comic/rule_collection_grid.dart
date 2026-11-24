import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'services/rule_browse_client.dart';

/// 作品一覧専用のCollection表示。
/// HTML取得・チャプター遷移は呼び出し元に任せる。
class RuleCollectionSliver extends StatelessWidget {
  const RuleCollectionSliver({
    super.key,
    required this.items,
    required this.onOpen,
  });

  final List<RuleBrowseItem> items;
  final ValueChanged<RuleBrowseItem> onOpen;

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.crossAxisExtent;
      const spacing = 10.0;

      // スマホは基本3列。極端に狭い領域では1～2列にする。
      final columns = width < 180
          ? 1
          : width < 330
          ? 2
          : width < 600
          ? 3
          : (width / 170).floor().clamp(3, 8).toInt();

      final cardWidth = math.max(
        1.0,
        (width - spacing * (columns - 1)) / columns,
      );

      final titleStyle = DefaultTextStyle.of(context).style.copyWith(
        fontSize: 14,
        height: 1.3,
        color: Colors.white,
        fontWeight: FontWeight.w400,
      );

      // 文字拡大設定も考慮して、2行分の領域を先に確保する。
      final painter = TextPainter(
        text: TextSpan(text: '作品名\n作品名', style: titleStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout();

      final titleHeight = painter.height.ceilToDouble() + 2;
      painter.dispose();

      final coverHeight = cardWidth * 1.5;
      final metadataStyle = titleStyle.copyWith(
        fontSize: 12,
        color: Colors.white60,
      );

      final hasMetadata = items.any(
        (item) =>
            item.latestChapter.trim().isNotEmpty || item.date.trim().isNotEmpty,
      );

      final metadataPainter = TextPainter(
        text: TextSpan(text: '最新話\n公開日', style: metadataStyle),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout();

      final metadataHeight = hasMetadata
          ? metadataPainter.height.ceilToDouble() + 2
          : 0.0;
      metadataPainter.dispose();

      final extent =
          coverHeight +
          8 +
          titleHeight +
          (hasMetadata ? 4 + metadataHeight : 0);

      return SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 16,
          mainAxisExtent: extent,
        ),
        delegate: SliverChildBuilderDelegate((context, index) {
          final item = items[index];
          return _CollectionCard(
            item: item,
            coverHeight: coverHeight,
            titleHeight: titleHeight,
            titleStyle: titleStyle,
            metadataStyle: metadataStyle,
            metadataHeight: metadataHeight,
            onTap: item.url == null ? null : () => onOpen(item),
          );
        }, childCount: items.length),
      );
    },
  );
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({
    required this.item,
    required this.coverHeight,
    required this.titleHeight,
    required this.titleStyle,
    required this.metadataStyle,
    required this.metadataHeight,
    required this.onTap,
  });

  final RuleBrowseItem item;
  final double coverHeight;
  final double titleHeight;
  final TextStyle titleStyle;
  final TextStyle metadataStyle;
  final double metadataHeight;
  final VoidCallback? onTap;

  Widget _placeholder({bool failed = false}) => ColoredBox(
    color: const Color(0xFF202020),
    child: Center(
      child: Icon(
        failed ? Icons.broken_image_outlined : Icons.image_outlined,
        color: Colors.white38,
        size: 36,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final thumbnail = item.thumbnail;
    final metadata = [
      item.latestChapter.trim(),
      item.date.trim(),
    ].where((value) => value.isNotEmpty).join('  ');

    return Semantics(
      button: onTap != null,
      label: item.title,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: coverHeight,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: thumbnail == null
                      ? _placeholder()
                      : Image.network(
                          thumbnail.toString(),
                          fit: BoxFit.cover,
                          // collection-cover-original-resolution-v1
                          // 横長画像を幅だけで縮小してから再拡大しない。
                          filterQuality: FilterQuality.medium,
                          frameBuilder:
                              (context, child, frame, wasSynchronouslyLoaded) {
                                if (wasSynchronouslyLoaded || frame != null) {
                                  return child;
                                }
                                return _placeholder();
                              },
                          errorBuilder: (_, error, stackTrace) =>
                              _placeholder(failed: true),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: titleHeight,
                child: Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: titleStyle,
                ),
              ),
              if (metadataHeight > 0) ...[
                const SizedBox(height: 4),
                SizedBox(
                  height: metadataHeight,
                  child: Text(
                    metadata,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: metadataStyle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
