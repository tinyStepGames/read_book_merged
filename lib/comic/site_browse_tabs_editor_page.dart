import 'package:flutter/material.dart';

import 'editor_unsaved_changes.dart';

import 'list_rule_lab_page.dart';
import 'services/download_store.dart';
import 'services/list_extraction_rule.dart';
import 'services/site_browse_tab.dart';
import 'services/site_rule_store.dart';

class SiteBrowseTabsEditorPage extends StatefulWidget {
  const SiteBrowseTabsEditorPage({
    super.key,
    required this.store,
    required this.site,
  });

  final DownloadStore store;
  final SavedSiteRule site;

  @override
  State<SiteBrowseTabsEditorPage> createState() =>
      _SiteBrowseTabsEditorPageState();
}

class _SiteBrowseTabsEditorPageState extends State<SiteBrowseTabsEditorPage> {
  late SavedSiteRule _site;
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    _site = widget.site;
  }

  Future<void> _persist(List<SiteBrowseTab> tabs) async {
    if (_busy) throw StateError('別の操作を処理中です');

    setState(() => _busy = true);

    try {
      final saved = await SiteRuleStore(widget.store.root).saveBrowseTabs(
        id: _site.id,
        tabs: tabs,
        expectedUpdatedAt: _site.updatedAt,
      );

      if (!mounted) return;

      setState(() {
        _site = saved;
        _status = 'タブ設定を保存しました。';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([SiteBrowseTab? existing]) async {
    if (_busy) return;

    if (existing == null && _site.browseTabs.length >= SiteBrowseTab.maxTabs) {
      setState(() => _status = '追加できるタブは12個までです。');
      return;
    }

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _SiteBrowseTabForm(
          store: widget.store,
          site: _site,
          initial: existing,
          onSave: (tab) async {
            final tabs = List<SiteBrowseTab>.of(_site.browseTabs);
            final index = tabs.indexWhere((item) => item.id == tab.id);

            if (index < 0) {
              tabs.add(tab);
            } else {
              tabs[index] = tab;
            }

            await _persist(tabs);
          },
        ),
      ),
    );
  }

  Future<void> _move(int index, int offset) async {
    if (_busy) return;

    final next = index + offset;
    if (next < 0 || next >= _site.browseTabs.length) return;

    final tabs = List<SiteBrowseTab>.of(_site.browseTabs);
    final tab = tabs.removeAt(index);
    tabs.insert(next, tab);

    try {
      await _persist(tabs);
    } catch (error) {
      if (mounted) {
        setState(() => _status = '並び替えできませんでした：$error');
      }
    }
  }

  Future<void> _delete(SiteBrowseTab tab) async {
    if (_busy) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('タブを削除'),
        content: Text(
          '「${tab.title}」のタブ設定を削除しますか？\n'
          '通常一覧や保存画像は削除しません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('削除'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    try {
      await _persist(
        _site.browseTabs.where((item) => item.id != tab.id).toList(),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _status = '削除できませんでした：$error');
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(title: const Text('サイト内タブ')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_site.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(
            '通常の「作品一覧」は先頭に残ります。'
            'その右側に表示するタブを追加してください。\n'
            '追加・編集・並び替え・削除は、その操作で保存されます。',
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _busy ? null : () => _edit(),
            icon: const Icon(Icons.add),
            label: const Text('タブを追加'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 3,
            child: _busy ? const LinearProgressIndicator() : null,
          ),
          const SizedBox(height: 12),
          for (var index = 0; index < _site.browseTabs.length; index++)
            Card(
              key: ValueKey(_site.browseTabs[index].id),
              child: Column(
                children: [
                  ListTile(
                    title: Text(_site.browseTabs[index].title),
                    subtitle: Text(
                      _site.browseTabs[index].pageUrl,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: _busy ? null : () => _edit(_site.browseTabs[index]),
                  ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        tooltip: '左へ移動',
                        onPressed: _busy || index == 0
                            ? null
                            : () => _move(index, -1),
                        icon: const Icon(Icons.arrow_back),
                      ),
                      IconButton(
                        tooltip: '右へ移動',
                        onPressed: _busy || index == _site.browseTabs.length - 1
                            ? null
                            : () => _move(index, 1),
                        icon: const Icon(Icons.arrow_forward),
                      ),
                      IconButton(
                        tooltip: '編集',
                        onPressed: _busy
                            ? null
                            : () => _edit(_site.browseTabs[index]),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                      IconButton(
                        tooltip: '削除',
                        onPressed: _busy
                            ? null
                            : () => _delete(_site.browseTabs[index]),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          if (_site.browseTabs.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('追加されたタブはありません。'),
            ),
          const SizedBox(height: 12),
          SelectableText(
            _status,
            style: const TextStyle(color: Colors.white70),
          ),
          const SizedBox(height: 16),
          const Text(
            'タブの内容は作品一覧として扱います。'
            '「ジャンル」という名前を付けても、'
            'ジャンル名を一覧表示する別機能にはなりません。\n'
            'タブ設定はサイト一式のJSON・QRに含まれます。',
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    ),
  );
}

class _SiteBrowseTabForm extends StatefulWidget {
  const _SiteBrowseTabForm({
    required this.store,
    required this.site,
    required this.initial,
    required this.onSave,
  });

  final DownloadStore store;
  final SavedSiteRule site;
  final SiteBrowseTab? initial;
  final Future<void> Function(SiteBrowseTab tab) onSave;

  @override
  State<_SiteBrowseTabForm> createState() => _SiteBrowseTabFormState();
}

class _SiteBrowseTabFormState extends State<_SiteBrowseTabForm>
    with EditorUnsavedChanges<_SiteBrowseTabForm> {
  @override
  bool get editorBusy => _busy;

  @override
  List<TextEditingController> get editorInputs => [_title, _url, _pagination];

  @override
  String get editorSnapshot => encodeEditorSnapshot({
    'title': _title.text.trim(),
    'url': _url.text.trim(),
    'pagination': _pagination.text.trim(),
    'source': _source,
    'rule': _source == 'custom' ? _customRule?.toJson() : null,
  });
  late final String _id;
  late final TextEditingController _title;
  late final TextEditingController _url;
  late final TextEditingController _pagination;

  String _source = 'works';
  ListExtractionRule? _customRule;
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();

    final tab = widget.initial;
    final works = widget.site.rules['works']!;

    _id = tab?.id ?? newSiteBrowseTabId();
    _title = TextEditingController(text: tab?.title ?? '');
    _url = TextEditingController(text: tab?.pageUrl ?? works.pageUrl);
    _pagination = TextEditingController(text: tab?.paginationUrl ?? '');
    _source = tab?.ruleSource ?? 'works';
    _customRule = tab?.customRule;
  }

  @override
  void dispose() {
    _title.dispose();
    _url.dispose();
    _pagination.dispose();
    super.dispose();
  }

  SiteBrowseTab _tab({ListExtractionRule? editedRule}) => SiteBrowseTab(
    id: _id,
    title: _title.text.trim(),
    pageUrl: _url.text.trim(),
    paginationUrl: _pagination.text.trim(),
    ruleSource: editedRule == null ? _source : 'custom',
    customRule: editedRule ?? (_source == 'custom' ? _customRule : null),
  );

  Future<void> _persist({ListExtractionRule? editedRule}) async {
    if (_busy) throw StateError('別の操作を処理中です');

    final tab = _tab(editedRule: editedRule);
    tab.validateFor(widget.site.rules);

    setState(() => _busy = true);

    try {
      await widget.onSave(tab);

      if (!mounted) return;

      setState(() {
        _source = tab.ruleSource;
        _customRule = tab.customRule;
        markEditorSaved();
        _status = 'タブを保存しました。追加の保存操作は不要です。';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    try {
      await _persist();
    } catch (error) {
      if (mounted) {
        setState(() => _status = '保存できませんでした：$error');
      }
    }
  }

  Future<void> _editRule() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    try {
      final fallback =
          _customRule ??
          widget.site.tagNavigation?.rule ??
          widget.site.rules['works']!;

      final initial = ListExtractionRule(
        pageUrl: _url.text.trim(),
        groupSelector: fallback.groupSelector,
        fields: Map.of(fallback.fields),
        details: Map.of(fallback.details),
        acquisition: fallback.acquisition,
        kind: 'works',
        paginationUrl: _pagination.text.trim(),
      );

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ListRuleLabPage(
            store: widget.store,
            initialPage: null,
            initialUrl: initial.pageUrl,
            initialSelector: initial.groupSelector,
            initialAcquisition: initial.acquisition,
            initialRule: initial,
            savedSite: widget.site,
            rulePurpose: 'タブ',
            onSaveRule: (rule) async {
              _url.text = rule.pageUrl;
              _pagination.text = rule.paginationUrl;
              await _persist(editedRule: rule);
            },
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _status = '編集画面を開けませんでした：$error');
      }
    }
  }

  @override
  Widget build(BuildContext context) => guardEditor(_buildEditor(context));

  Widget _buildEditor(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(leading: editorBackButton, title: const Text('タブを編集')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _title,
            enabled: !_busy,
            maxLength: 40,
            decoration: const InputDecoration(
              labelText: 'タブ名',
              hintText: '例：最新、人気、ランキング',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: '先頭ページのURL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pagination,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'ページ送りURL（任意）',
              helperText: 'ページ番号を {page;1} に置き換えて指定',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _source,
            decoration: const InputDecoration(
              labelText: '作品を取得するルール',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'works', child: Text('通常の作品一覧')),
              DropdownMenuItem(value: 'tags', child: Text('タグ先の作品一覧')),
              DropdownMenuItem(value: 'custom', child: Text('このタブ専用')),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) {
                      setState(() => _source = value);
                    }
                  },
          ),
          const SizedBox(height: 8),
          const Text(
            '通常一覧・タグ先を選んだ場合、'
            'セレクターや通常HTML／表示後HTMLの設定を引き継ぎます。\n'
            'タグ先が未設定なら通常一覧を使います。\n'
            '取得先URLとページ送りは、このタブに入力した値を使います。',
            style: TextStyle(color: Colors.white60),
          ),
          if (_source == 'custom') ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _busy ? null : _editRule,
              icon: const Icon(Icons.tune),
              label: const Text('専用ルールを編集・テスト'),
            ),
            const Text(
              '先にタブ名とURLを入力してください。'
              '編集画面の「サイトに保存」で、タブ設定も一緒に保存します。',
              style: TextStyle(color: Colors.white60),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('タブを保存'),
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 3,
            child: _busy ? const LinearProgressIndicator() : null,
          ),
          const SizedBox(height: 12),
          SelectableText(
            _status,
            style: const TextStyle(color: Colors.white70),
          ),
        ],
      ),
    ),
  );
}
