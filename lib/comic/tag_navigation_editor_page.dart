import 'package:flutter/material.dart';

import 'editor_unsaved_changes.dart';

import 'list_rule_lab_page.dart';
import 'services/download_store.dart';
import 'services/html_probe.dart';
import 'services/list_extraction_rule.dart';
import 'services/site_rule_store.dart';
import 'services/tag_navigation_settings.dart';

class TagNavigationEditorPage extends StatefulWidget {
  const TagNavigationEditorPage({
    super.key,
    required this.store,
    required this.site,
  });

  final DownloadStore store;
  final SavedSiteRule site;

  @override
  State<TagNavigationEditorPage> createState() =>
      _TagNavigationEditorPageState();
}

class _TagNavigationEditorPageState extends State<TagNavigationEditorPage>
    with EditorUnsavedChanges<TagNavigationEditorPage> {
  @override
  bool get editorBusy => _busy;

  @override
  List<TextEditingController> get editorInputs => [_pattern, _replacement];

  @override
  String get editorSnapshot => encodeEditorSnapshot({
    'rule': _draftRule.toJson(),
    'pattern': _pattern.text,
    'replacement': _replacement.text,
  });
  late SavedSiteRule _site;
  late ListExtractionRule _draftRule;
  late final TextEditingController _pattern;
  late final TextEditingController _replacement;
  late final TextEditingController _previewInput;

  bool _busy = false;
  String _status = '';
  String _preview = '';

  @override
  void initState() {
    super.initState();
    _site = widget.site;

    final settings = _site.tagNavigation;
    final fallback = _site.rules['works'] ?? _site.rules.values.first;

    _draftRule =
        settings?.rule ??
        ListExtractionRule(
          pageUrl: fallback.pageUrl,
          groupSelector: fallback.groupSelector,
          fields: Map.of(fallback.fields),
          kind: 'works',
          acquisition: fallback.acquisition,
          details: Map.of(fallback.details),
          paginationUrl: fallback.kind == 'works' ? fallback.paginationUrl : '',
        );

    _pattern = TextEditingController(text: settings?.urlPattern ?? '');
    _replacement = TextEditingController(text: settings?.urlReplacement ?? '');
    _previewInput = TextEditingController();

    _status = settings == null
        ? '専用設定は未保存です。通常一覧の設定を下地にしています。'
        : 'タグ先専用の設定を開きました。';
  }

  @override
  void dispose() {
    _pattern.dispose();
    _replacement.dispose();
    _previewInput.dispose();
    super.dispose();
  }

  Future<void> _editRule() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ListRuleLabPage(
          store: widget.store,
          initialPage: null,
          initialUrl: _draftRule.pageUrl,
          initialSelector: _draftRule.groupSelector,
          initialAcquisition: _draftRule.acquisition,
          initialRule: _draftRule,
          savedSite: _site,
          onSaveRule: _saveRuleDirectly,
        ),
      ),
    );
  }

  Future<void> _saveRuleDirectly(ListExtractionRule rule) async {
    if (!mounted) {
      throw StateError('タグ設定画面を開き直してください');
    }

    if (_busy) {
      throw StateError('別の操作を処理中です。少し待って再試行してください');
    }

    final checked = ListExtractionRule.parse(rule.encodeJson());

    if (checked.kind != 'works') {
      throw const FormatException('タグ先には作品一覧を設定してください');
    }

    final settings = TagNavigationSettings(
      rule: checked,
      urlPattern: _pattern.text,
      urlReplacement: _replacement.text,
    );

    settings.validateFor(_site.rules.values);

    setState(() => _busy = true);

    try {
      final saved = await SiteRuleStore(widget.store.root).saveTagNavigation(
        id: _site.id,
        settings: settings,
        expectedUpdatedAt: _site.updatedAt,
      );

      if (!mounted) return;

      setState(() {
        _site = saved;
        _draftRule = checked;
        markEditorSaved();
        _status =
            'タグ先の一覧ルールとURL変換設定を保存しました。'
            '追加の保存操作は不要です。';
      });
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _testUrl() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    setState(() {
      _busy = true;
      _preview = '';
    });

    try {
      final target = await resolveTagNavigationUrl(
        input: htmlProbeUri(_previewInput.text.trim()),
        allowedOrigin: htmlProbeUri(_draftRule.pageUrl).origin,
        pattern: _pattern.text,
        replacement: _replacement.text,
      );

      if (mounted) {
        setState(() {
          _preview = target.toString();
          _status = 'URL変換を確認しました。通信・保存は行っていません。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'URLを変換できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    setState(() => _busy = true);

    try {
      final settings = TagNavigationSettings(
        rule: _draftRule,
        urlPattern: _pattern.text,
        urlReplacement: _replacement.text,
      );

      settings.validateFor(_site.rules.values);

      final saved = await SiteRuleStore(widget.store.root).saveTagNavigation(
        id: _site.id,
        settings: settings,
        expectedUpdatedAt: _site.updatedAt,
      );

      if (!mounted) return;

      setState(() {
        _site = saved;
        markEditorSaved();
        _status =
            'タグ先設定を保存しました。'
            '通常の作品一覧・チャプター・本文画像の設定は保持しています。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '保存できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    if (_busy || _site.tagNavigation == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('タグ先専用設定を削除'),
        content: const Text(
          'タグ先の一覧設定とURL変換を削除し、'
          '通常の作品一覧ルールを使う状態へ戻します。\n\n'
          '通常一覧・チャプター・本文画像・保存画像は削除しません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('専用設定を削除'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    setState(() => _busy = true);

    try {
      final saved = await SiteRuleStore(widget.store.root).saveTagNavigation(
        id: _site.id,
        settings: null,
        expectedUpdatedAt: _site.updatedAt,
      );

      if (!mounted) return;

      setState(() {
        _site = saved;
        _pattern.clear();
        _replacement.clear();
        _preview = '';
        markEditorSaved();
        _status =
            'タグ先専用設定を削除しました。'
            '通常の作品一覧ルールを使用します。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '削除できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => guardEditor(_buildEditor(context));

  Widget _buildEditor(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(leading: editorBackButton, title: const Text('タグ先の作品一覧')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_site.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(
            'タグを押した先の作品一覧だけに使う設定です。'
            '通常の作品一覧は上書きしません。',
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : _editRule,
            icon: const Icon(Icons.tune),
            label: const Text('タグ先の一覧ルールを編集・テスト'),
          ),
          const SizedBox(height: 8),
          SelectableText(
            'サンプルURL：${_draftRule.pageUrl}\n'
            'まとまり：${_draftRule.groupSelector}\n'
            '取得方式：'
            '${_draftRule.acquisition == 'renderedDom' ? '表示後HTML' : '通常HTML'}',
          ),
          const SizedBox(height: 24),
          Text('タグURLの変換（任意）', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          const Text(
            '両方空欄ならタグのリンク先をそのまま開きます。'
            'URLの形式を変更したいサイトだけ設定してください。',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pattern,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'タグURLの正規表現',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _replacement,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            minLines: 1,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'URL整形テンプレート',
              helperText: r'$1・$2＝取得した部分、$$＝ドル記号',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _previewInput,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '変換テスト用のタグURL',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _testUrl,
            icon: const Icon(Icons.preview_outlined),
            label: const Text('URL変換をテスト'),
          ),
          if (_preview.isNotEmpty) ...[
            const SizedBox(height: 8),
            SelectableText(_preview),
            const SizedBox(height: 8),
            const Text(
              '必要ならこのURLをコピーし、'
              '一覧ルールのサンプルURLとして使ってください。',
            ),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('URL変換設定を保存'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy || _site.tagNavigation == null ? null : _remove,
            child: const Text('専用設定を削除して通常一覧を使う'),
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
            '一覧編集画面の「サイトに保存」で、一覧ルールと入力済みのURL変換設定を保存します。'
            '前の画面に戻って保存し直す必要はありません。URL変換だけを変更した場合は、この画面の保存ボタンを使ってください。\n\n'
            '共有するときは「サイト一式のJSON・QR」を使ってください。'
            '単一の一覧JSONには、この画面のURL変換設定は含まれません。',
            style: TextStyle(color: Colors.white54),
          ),
        ],
      ),
    ),
  );
}
