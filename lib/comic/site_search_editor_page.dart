import 'package:flutter/material.dart';

import 'editor_unsaved_changes.dart';

import 'list_rule_lab_page.dart';
import 'services/download_store.dart';
import 'services/list_extraction_rule.dart';
import 'services/site_rule_store.dart';
import 'services/site_search_settings.dart';

class SiteSearchEditorPage extends StatefulWidget {
  const SiteSearchEditorPage({
    super.key,
    required this.store,
    required this.site,
  });

  final DownloadStore store;
  final SavedSiteRule site;

  @override
  State<SiteSearchEditorPage> createState() => _SiteSearchEditorPageState();
}

class _SiteSearchEditorPageState extends State<SiteSearchEditorPage>
    with EditorUnsavedChanges<SiteSearchEditorPage> {
  @override
  bool get editorBusy => _busy;

  @override
  List<TextEditingController> get editorInputs => [_url];

  @override
  String get editorSnapshot => encodeEditorSnapshot({
    'url': _url.text.trim(),
    'normalizeSpaces': _normalizeSpaces,
    'encoding': _encoding,
    'useCustom': _useCustom,
    'rule': _useCustom ? _customRule?.toJson() : null,
  });
  late SavedSiteRule _site;
  late final TextEditingController _url;
  late final TextEditingController _query;

  ListExtractionRule? _customRule;
  bool _useCustom = false;
  bool _normalizeSpaces = true;
  String _encoding = 'plus';
  bool _busy = false;
  String _status = '';
  String _preview = '';

  @override
  void initState() {
    super.initState();
    _site = widget.site;

    final settings = _site.searchSettings;
    final origin = Uri.parse(_site.rules.values.first.pageUrl).origin;

    _url = TextEditingController(
      text: settings?.urlTemplate ?? '$origin/?s={keyword}',
    );
    _query = TextEditingController(text: '魔法 学園');
    _customRule = settings?.rule;
    _useCustom = _customRule != null;
    _normalizeSpaces = settings?.normalizeSpaces ?? true;
    _encoding = settings?.spaceEncoding ?? 'plus';
  }

  @override
  void dispose() {
    _url.dispose();
    _query.dispose();
    super.dispose();
  }

  SiteSearchSettings _settings({ListExtractionRule? editedRule}) =>
      SiteSearchSettings(
        urlTemplate: _url.text.trim(),
        normalizeSpaces: _normalizeSpaces,
        spaceEncoding: _encoding,
        rule: editedRule ?? (_useCustom ? _customRule : null),
      );

  void _previewUrl() {
    try {
      final settings = _settings();
      settings.validateFor(_site.rules);

      setState(() {
        _preview = settings.template.url(_query.text);
        _status = 'URLを生成しました。通信・保存は行っていません。';
      });
    } catch (error) {
      setState(() {
        _preview = '';
        _status = 'URLを生成できませんでした：$error';
      });
    }
  }

  Future<void> _persist({ListExtractionRule? editedRule}) async {
    if (_busy) {
      throw StateError('別の操作を処理中です');
    }

    if (_useCustom && editedRule == null && _customRule == null) {
      throw const FormatException('先に検索結果の専用ルールを編集してください');
    }

    final settings = _settings(editedRule: editedRule);
    settings.validateFor(_site.rules);

    if (!mounted) return;
    setState(() => _busy = true);

    try {
      final saved = await SiteRuleStore(widget.store.root).saveSearchSettings(
        id: _site.id,
        settings: settings,
        expectedUpdatedAt: _site.updatedAt,
      );

      if (!mounted) return;

      setState(() {
        _site = saved;
        _customRule = saved.searchSettings?.rule;
        _useCustom = _customRule != null;
        markEditorSaved();
        _status = '検索設定を保存しました。追加の保存操作は不要です。';
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

  Future<void> _editResults() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    try {
      final settings = SiteSearchSettings(
        urlTemplate: _url.text.trim(),
        normalizeSpaces: _normalizeSpaces,
        spaceEncoding: _encoding,
      );
      settings.validateFor(_site.rules);

      final source =
          _customRule ?? _site.tagNavigation?.rule ?? _site.rules['works']!;
      final sample = settings.template.url(_query.text);

      final initial = ListExtractionRule(
        pageUrl: sample,
        groupSelector: source.groupSelector,
        fields: Map.of(source.fields),
        details: Map.of(source.details),
        kind: 'works',
        acquisition: source.acquisition,
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
            savedSite: _site,
            rulePurpose: '検索結果',
            onSaveRule: (rule) async {
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

  Future<void> _remove() async {
    if (_busy || _site.searchSettings == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('検索設定を削除'),
        content: const Text(
          'このサイトの検索設定だけを削除します。'
          '通常一覧・タグ・チャプター・本文画像は削除しません。',
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

    setState(() => _busy = true);

    try {
      final saved = await SiteRuleStore(widget.store.root).saveSearchSettings(
        id: _site.id,
        settings: null,
        expectedUpdatedAt: _site.updatedAt,
      );

      if (!mounted) return;

      setState(() {
        _site = saved;
        markEditorSaved();
        _status = '検索設定を削除しました。';
      });
    } catch (error) {
      if (mounted) setState(() => _status = '削除できませんでした：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => guardEditor(_buildEditor(context));

  Widget _buildEditor(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(leading: editorBackButton, title: const Text('検索設定')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_site.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(
            'GET方式の検索に対応しています。'
            '初期URLは仮の例なので、サイトの実際の検索URLへ変更してください。',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            maxLines: 4,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: '検索URLテンプレート',
              helperText: '{keyword}を1個、必要なら{page;1}も指定',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _encoding,
            decoration: const InputDecoration(
              labelText: 'クエリ内のスペースの送信方法',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: 'plus', child: Text('+（フォーム方式）')),
              DropdownMenuItem(value: 'percent', child: Text('%20（パーセント方式）')),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) {
                      setState(() => _encoding = value);
                    }
                  },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('全角・連続スペースを通常のスペースに統一'),
            subtitle: const Text('無効でも入力前後の空白は除去します'),
            value: _normalizeSpaces,
            onChanged: _busy
                ? null
                : (value) => setState(() => _normalizeSpaces = value),
          ),
          TextField(
            controller: _query,
            enabled: !_busy,
            autocorrect: false,
            maxLength: 256,
            decoration: const InputDecoration(
              labelText: 'テスト用の検索語',
              border: OutlineInputBorder(),
            ),
          ),
          OutlinedButton.icon(
            onPressed: _busy ? null : _previewUrl,
            icon: const Icon(Icons.preview_outlined),
            label: const Text('生成URLを確認'),
          ),
          if (_preview.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(_preview),
          ],
          const Divider(height: 32),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('検索結果専用の抽出ルールを使う'),
            subtitle: const Text('無効ならタグ先の一覧ルールを優先し、未設定なら通常一覧を使います'),
            value: _useCustom,
            onChanged: _busy
                ? null
                : (value) => setState(() => _useCustom = value),
          ),
          if (_useCustom) ...[
            OutlinedButton.icon(
              onPressed: _busy ? null : _editResults,
              icon: const Icon(Icons.tune),
              label: const Text('検索結果ルールを編集・テスト'),
            ),
            const SizedBox(height: 8),
            const Text(
              'ページ送りは上の検索URLの {page;1} で設定します。'
              '一覧編集画面のページ送りURLは空欄にしてください。\n'
              '編集画面の「サイトに保存」で、検索URLと専用ルールを一緒に保存します。',
              style: TextStyle(color: Colors.white60),
            ),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('検索設定を保存'),
          ),
          OutlinedButton(
            onPressed: _busy || _site.searchSettings == null ? null : _remove,
            child: const Text('検索設定を削除'),
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
          const SizedBox(height: 16),
          const Text(
            '検索語は未加工の文字列で入力してください。'
            '%20などへの事前変換は不要です。\n'
            'AND・OR検索の意味はサイト側の検索仕様に従います。\n'
            '設定は「サイト一式のJSON・QR」に含まれます。',
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    ),
  );
}
