import 'site_browse_tabs_editor_page.dart';
import 'site_search_editor_page.dart';
import 'site_search_page.dart';
import 'tag_navigation_editor_page.dart';
import 'services/last_opened_site_store.dart';
import 'package:flutter/material.dart';

import 'list_rule_lab_page.dart';
import 'site_bundle_page.dart';
import 'rule_browse_page.dart';
import 'rule_saved_downloads_page.dart';
import 'chapter_image_lab_page.dart';
import 'services/download_store.dart';
import 'services/list_extraction_rule.dart';
import 'services/site_rule_store.dart';
import 'services/site_reading_settings.dart';
import 'site_reading_editor_page.dart';
import 'video_source_editor_page.dart';

class SiteRulesPage extends StatefulWidget {
  const SiteRulesPage({super.key, required this.store, this.initialSiteId});

  final String? initialSiteId;
  final DownloadStore store;

  @override
  State<SiteRulesPage> createState() => _SiteRulesPageState();
}

class _SiteRulesPageState extends State<SiteRulesPage> {
  late final SiteRuleStore _repository;
  List<SavedSiteRule> _sites = [];
  bool _busy = true;
  String _status = '保存設定を確認中';

  @override
  void initState() {
    super.initState();
    _repository = SiteRuleStore(widget.store.root);
    _load();
  }

  Future<void> _load() async {
    if (mounted) setState(() => _busy = true);
    try {
      final sites = await _repository.load();
      if (!mounted) return;
      setState(() {
        _sites = sites;
        _status = '${sites.length}サイトを保存しています';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '読み込めませんでした。保存データは変更していません：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _change(Future<void> Function() action, String success) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      final sites = await _repository.load();
      if (!mounted) return;
      setState(() {
        _sites = sites;
        _status = success;
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '操作できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askText({
    required String title,
    required String label,
    String initial = '',
  }) => showDialog<String>(
    context: context,
    builder: (_) => _RuleTextDialog(
      title: title,
      label: label,
      initial: initial,
      multiline: false,
    ),
  );

  Future<void> _edit(SavedSiteRule? site, String kind) async {
    if (_busy) return;

    final existing = site?.rules[kind];
    final fallback = site == null
        ? 'https://'
        : site.rules.values.first.pageUrl;
    final rule =
        existing ??
        ListExtractionRule(
          pageUrl: fallback,
          groupSelector: '',
          fields: defaultListFields(),
          kind: kind,
        );

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ListRuleLabPage(
          store: widget.store,
          initialPage: null,
          initialUrl: rule.pageUrl,
          initialSelector: rule.groupSelector,
          initialAcquisition: rule.acquisition,
          initialRule: rule,
          savedSite: site,
        ),
      ),
    );

    if (mounted) await _load();
  }

  Future<void> _editBrowseTabs(SavedSiteRule site) async {
    if (_busy) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            SiteBrowseTabsEditorPage(store: widget.store, site: site),
      ),
    );

    if (mounted) await _load();
  }

  Future<void> _editSearch(SavedSiteRule site) async {
    if (_busy) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SiteSearchEditorPage(store: widget.store, site: site),
      ),
    );

    if (mounted) await _load();
  }

  Future<void> _editTagNavigation(SavedSiteRule site) async {
    if (_busy) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            TagNavigationEditorPage(store: widget.store, site: site),
      ),
    );

    if (mounted) await _load();
  }

  Future<void> _editReading(SavedSiteRule site) async {
    if (_busy) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            SiteReadingEditorPage(repository: _repository, site: site),
      ),
    );

    if (mounted) await _load();
  }

  Future<void> _editVideo(SavedSiteRule site) async {
    if (_busy) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) =>
            VideoSourceEditorPage(repository: _repository, site: site),
      ),
    );

    if (mounted) await _load();
  }

  Future<void> _editImages(SavedSiteRule site) async {
    if (_busy) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChapterImageLabPage(
          initialUrl: site.images?.pageUrl ?? '',
          initialAcquisition: site.images?.acquisition ?? 'staticHtml',
          repository: _repository,
          savedSite: site,
        ),
      ),
    );

    if (mounted) await _load();
  }

  Future<void> _browse(SavedSiteRule site) async {
    if (_busy) return;

    try {
      await LastOpenedSiteStore(widget.store.root).write(site.id);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('起動サイトを保存できませんでした')));
    }

    if (!mounted) return;

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => RuleBrowsePage(site: site)),
    );
  }

  Future<void> _transferSite([SavedSiteRule? site]) async {
    if (_busy) return;

    await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) =>
            SiteBundlePage(repository: _repository, initialSite: site),
      ),
    );

    if (mounted) await _load();
  }

  Future<void> _menu(SavedSiteRule site, String action) async {
    if (_busy) return;

    if (action == 'bundle') {
      await _transferSite(site);
      return;
    }

    if (action == 'rename') {
      final name = await _askText(
        title: 'サイト名を変更',
        label: 'サイト保存名',
        initial: site.name,
      );
      if (!mounted || name == null) return;
      await _change(() => _repository.rename(site.id, name), 'サイト名を変更しました');
    } else if (action == 'duplicate') {
      await _change(() async {
        await _repository.duplicate(site.id);
      }, 'サイト設定を複製しました');
    } else if (action == 'delete') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('サイト設定を削除'),
          content: Text(
            '「${site.name}」の保存設定を削除しますか？\n\n'
            '作品一覧・チャプター一覧・本文画像の設定が対象です。'
            '保存画像・お気に入り・閲覧履歴は削除しません。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('削除する'),
            ),
          ],
        ),
      );

      if (!mounted || confirmed != true) return;
      await _change(() => _repository.delete(site.id), 'サイト設定を削除しました');
    }
  }

  Widget _slot(SavedSiteRule site, String kind, String label) {
    final rule = site.rules[kind];
    return ListTile(
      title: Text(label),
      subtitle: Text(
        rule == null ? '未設定・タップして設定' : '設定済み・タップして編集\n${rule.pageUrl}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
      leading: Icon(
        rule == null ? Icons.add_circle_outline : Icons.check_circle_outline,
      ),
      onTap: _busy ? null : () => _edit(site, kind),
    );
  }

  Widget _card(SavedSiteRule site) => Card(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            title: Text(
              site.name,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            subtitle: Text(
              '設定保存：${site.updatedAt.toLocal().toString().split('.').first}',
            ),
            trailing: PopupMenuButton<String>(
              enabled: !_busy,
              onSelected: (value) => _menu(site, value),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'bundle', child: Text('サイト一式のJSON・QR')),
                PopupMenuItem(value: 'rename', child: Text('名前変更')),
                PopupMenuItem(value: 'duplicate', child: Text('複製')),
                PopupMenuItem(value: 'delete', child: Text('削除')),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: FilledButton.icon(
              onPressed: _busy || !site.rules.containsKey('works')
                  ? null
                  : () => _browse(site),
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('作品一覧を開く'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: const Text('保存済みを開く'),
            subtitle: const Text('通信せずに保存した話を読みます'),
            onTap: _busy
                ? null
                : () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => RuleSavedDownloadsPage(site: site),
                      ),
                    );
                  },
          ),
          _slot(site, 'works', '作品一覧'),
          ListTile(
            leading: const Icon(Icons.tab_outlined),
            title: const Text('サイト内タブ'),
            subtitle: Text(
              site.browseTabs.isEmpty
                  ? '未設定・最新や人気などのタブを追加'
                  : '${site.browseTabs.length}個の追加タブ・タップして編集',
            ),
            onTap: _busy || !site.rules.containsKey('works')
                ? null
                : () => _editBrowseTabs(site),
          ),
          ListTile(
            leading: Icon(
              site.searchSettings == null
                  ? Icons.search
                  : Icons.check_circle_outline,
            ),
            title: const Text('検索設定'),
            subtitle: Text(
              site.searchSettings == null
                  ? '未設定・タップして設定'
                  : '設定済み・タップして編集\n'
                        '${site.searchSettings!.urlTemplate}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: _busy ? null : () => _editSearch(site),
            trailing: site.searchSettings == null
                ? null
                : IconButton(
                    tooltip: 'このサイトを検索',
                    onPressed: _busy
                        ? null
                        : () {
                            Navigator.of(context).push<void>(
                              MaterialPageRoute<void>(
                                builder: (_) => SiteSearchPage(site: site),
                              ),
                            );
                          },
                    icon: const Icon(Icons.search),
                  ),
          ),
          ListTile(
            leading: Icon(
              site.tagNavigation == null
                  ? Icons.label_outline
                  : Icons.check_circle_outline,
            ),
            title: const Text('タグ先の作品一覧'),
            subtitle: Text(
              site.tagNavigation == null
                  ? '未設定・通常の作品一覧ルールを使用'
                  : '専用設定あり・タップして編集\n'
                        '${site.tagNavigation!.rule.pageUrl}',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: _busy ? null : () => _editTagNavigation(site),
          ),
          ListTile(
            leading: const Icon(Icons.alt_route),
            title: const Text('一覧からの開き方'),
            subtitle: Text(site.readingMode.label),
            onTap: _busy ? null : () => _editReading(site),
          ),
          if (site.readingMode == SiteReadingMode.chapters)
            _slot(site, 'chapters', 'チャプター一覧'),
          ListTile(
            leading: const Icon(Icons.ondemand_video),
            title: const Text('動画設定・再生テスト'),
            subtitle: Text(
              site.readingSettings?.video == null
                  ? '未設定・抽出と再生を確認'
                  : '動画再生を使用・タップして編集',
            ),
            onTap: _busy ? null : () => _editVideo(site),
          ),
          ListTile(
            title: const Text('本文画像'),
            subtitle: Text(
              site.images == null
                  ? '未設定・タップして設定'
                  : '設定済み・タップして編集\n'
                        '${site.images!.acquisition == 'renderedDom' ? '表示後HTML' : '通常HTML'}'
                        ' ／ ${site.images!.rule.attribute}',
            ),
            leading: Icon(
              site.images == null
                  ? Icons.add_photo_alternate_outlined
                  : Icons.check_circle_outline,
            ),
            onTap: _busy ? null : () => _editImages(site),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Text(
              'チャプター一覧から読書・ダウンロードできます。'
              '保存済みの話は通信せずに開けます。',
              style: TextStyle(color: Colors.white54),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: const Text('サイトルール管理'),
      actions: [
        IconButton(
          tooltip: '再読み込み',
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: _busy ? null : () => _edit(null, 'works'),
                icon: const Icon(Icons.add),
                label: const Text('新規サイトルール作成'),
              ),

              OutlinedButton.icon(
                onPressed: _busy ? null : () => _transferSite(),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('サイト一式を取り込む'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 3,
            child: _busy ? const LinearProgressIndicator() : null,
          ),
          const SizedBox(height: 12),
          SelectableText(
            _status,
            style: const TextStyle(color: Colors.tealAccent),
          ),
          const SizedBox(height: 12),
          if (!_busy && _sites.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '保存されたサイトはありません。\n'
                '既存の一覧編集画面から「サイトに保存」することもできます。',
              ),
            ),
          for (final site in _sites.where(
            (site) =>
                widget.initialSiteId == null || site.id == widget.initialSiteId,
          ))
            KeyedSubtree(key: ValueKey(site.id), child: _card(site)),
        ],
      ),
    ),
  );
}

class _RuleTextDialog extends StatefulWidget {
  const _RuleTextDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.multiline,
  });

  final String title;
  final String label;
  final String initial;
  final bool multiline;

  @override
  State<_RuleTextDialog> createState() => _RuleTextDialogState();
}

class _RuleTextDialogState extends State<_RuleTextDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 500,
      child: SingleChildScrollView(
        child: TextField(
          controller: _controller,
          autofocus: true,
          autocorrect: false,
          minLines: widget.multiline ? 5 : 1,
          maxLines: widget.multiline ? 10 : 1,
          decoration: InputDecoration(
            labelText: widget.label,
            border: const OutlineInputBorder(),
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('キャンセル'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _controller.text),
        child: const Text('次へ'),
      ),
    ],
  );
}
