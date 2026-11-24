import 'package:flutter/material.dart';

import 'services/site_import_comparison.dart';

class SiteImportComparisonPanel extends StatelessWidget {
  const SiteImportComparisonPanel({super.key, required this.comparison});

  final SiteImportComparison comparison;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('反映内容の比較', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(comparison.actionText),
            if (comparison.hasRemovals) ...[
              const SizedBox(height: 12),
              Container(
                key: const ValueKey('site-import-removal-warning'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.orange),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '削除される設定があります',
                      style: TextStyle(
                        color: Colors.orange,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final label in comparison.removedLabels)
                      Text('・$label'),
                    const SizedBox(height: 8),
                    const Text('取り込み側にない設定は残りません。'),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            for (final change in comparison.changes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(change.label)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        change.statusLabel,
                        textAlign: TextAlign.end,
                        style: TextStyle(
                          color: change.kind == SiteImportChangeKind.removed
                              ? Colors.orange
                              : null,
                          fontWeight:
                              change.kind == SiteImportChangeKind.unchanged ||
                                  change.kind ==
                                      SiteImportChangeKind.unconfigured
                              ? FontWeight.normal
                              : FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(height: 24),
            const Text(SiteImportComparison.referenceNotice),
            const SizedBox(height: 8),
            const Text(
              '比較しただけでは通信・保存しません。'
              '保存画像・お気に入り・履歴などの個人データは対象外です。',
            ),
          ],
        ),
      ),
    );
  }
}
