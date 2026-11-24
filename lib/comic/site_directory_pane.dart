import 'package:flutter/material.dart';

import 'services/site_rule_store.dart';

class SiteDirectoryPane extends StatelessWidget {
  const SiteDirectoryPane({
    super.key,
    required this.sites,
    required this.activeSiteId,
    required this.busy,
    required this.error,
    required this.onOpen,
    required this.onManage,
    required this.onLab,
    required this.onRefresh,
  });

  final List<SavedSiteRule> sites;

  /// nullは内蔵のペッパー＆キャロットを表す。
  final String? activeSiteId;
  final bool busy;
  final String? error;
  final ValueChanged<SavedSiteRule?> onOpen;
  final ValueChanged<SavedSiteRule?> onManage;
  final VoidCallback onLab;
  final VoidCallback onRefresh;

  String _address(SavedSiteRule site) {
    final rule = site.rules['works'];
    if (rule == null) return '作品一覧が未設定です';

    final uri = Uri.tryParse(rule.pageUrl);
    return uri?.host.isNotEmpty == true ? uri!.host : rule.pageUrl;
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        key: const PageStorageKey<String>('site-directory'),
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: busy ? null : onLab,
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('新規サイトルール作成'),
              ),
              OutlinedButton.icon(
                onPressed: busy ? null : () => onManage(null),
                icon: const Icon(Icons.settings_outlined),
                label: const Text('サイト管理・JSON／QR'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 3,
            child: busy ? const LinearProgressIndicator() : null,
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: const TextStyle(color: Colors.orangeAccent)),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: busy ? null : onRefresh,
                child: const Text('再読み込み'),
              ),
            ),
          ],
          const SizedBox(height: 12),
          for (final site in sites)
            Card(
              key: ValueKey('directory-site-${site.id}'),
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                leading: const CircleAvatar(child: Icon(Icons.language)),
                title: Text(
                  site.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  [
                    _address(site),
                    if (activeSiteId == site.id) '選択中',
                  ].join('\n'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => site.rules.containsKey('works')
                    ? onOpen(site)
                    : onManage(site),
                trailing: IconButton(
                  tooltip: '${site.name}の設定',
                  onPressed: () => onManage(site),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ),
            ),
          if (!busy && error == null && sites.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '作成したサイトはここに表示されます。\n'
                '「新規サイトルール作成」で作成するか、'
                '「サイト管理・JSON／QR」から取り込めます。',
                style: TextStyle(color: Colors.white60),
              ),
            ),
          const SizedBox(height: 20),
          const Text('内蔵サンプル', style: TextStyle(color: Colors.white54)),
          const SizedBox(height: 8),
          Card(
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.auto_stories_outlined),
              ),
              title: const Text('ペッパー＆キャロット'),
              subtitle: Text(activeSiteId == null ? '内蔵サンプル・選択中' : '内蔵サンプル'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => onOpen(null),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
