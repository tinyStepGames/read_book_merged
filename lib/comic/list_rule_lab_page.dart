import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'rule_acquisition_notice.dart';

import 'editor_unsaved_changes.dart';

import 'element_inspector_page.dart';
import 'work_details_editor_page.dart';
import 'services/download_store.dart';
import 'services/html_probe.dart';
import 'services/rule_diagnostics.dart';
import 'services/list_extraction_rule.dart';
import 'services/list_field_pick.dart';
import 'services/site_rule_store.dart';

class ListRuleLabPage extends StatefulWidget {
  const ListRuleLabPage({
    super.key,
    required this.store,
    required this.initialPage,
    required this.initialUrl,
    required this.initialSelector,
    required this.initialAcquisition,
    this.initialRule,
    this.savedSite,
    this.onSaveRule,
    this.rulePurpose = 'タグ先',
  });

  final DownloadStore store;
  final HtmlProbePage? initialPage;
  final String initialUrl;
  final String initialSelector;
  final String initialAcquisition;
  final ListExtractionRule? initialRule;
  final SavedSiteRule? savedSite;
  final Future<void> Function(ListExtractionRule rule)? onSaveRule;
  final String rulePurpose;

  @override
  State<ListRuleLabPage> createState() => _ListRuleLabPageState();
}

class _ListRuleLabPageState extends State<ListRuleLabPage>
    with EditorUnsavedChanges<ListRuleLabPage> {
  @override
  bool get editorBusy => _busy;

  @override
  List<TextEditingController> get editorInputs => [
    _url,
    _group,
    _paginationUrl,
    _siteName,
  ];

  @override
  String get editorSnapshot => encodeEditorSnapshot({
    if (widget.onSaveRule == null) 'name': _siteName.text.trim(),
    'url': _url.text.trim(),
    'group': _group.text.trim(),
    'pagination': _paginationUrl.text.trim(),
    'kind': _kind,
    'acquisition': _acquisition,
    'fields': {
      for (final entry in _fields.entries) entry.key: entry.value.toJson(),
    },
    'details': {
      for (final entry in _details.entries) entry.key: entry.value.toJson(),
    },
  });
  static const _cacheKey = 'rule-lab:list-draft:v1';

  late final TextEditingController _url;
  late final TextEditingController _group;
  late final TextEditingController _paginationUrl;
  late final TextEditingController _siteName;
  String? _savedSiteId;
  final _client = HtmlProbeClient();
  CancelToken? _cancel;
  HtmlProbePage? _page;
  late String _acquisition;
  String _kind = 'works';
  Map<String, ListFieldRule> _fields = defaultListFields();
  ListExtractionReport? _report;
  Map<String, ListFieldRule> _details = {};
  bool _busy = false;
  bool _showImages = false;
  int _revision = 0;
  String _status = '1作品／1話を囲む要素を指定してください';

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialUrl);
    _group = TextEditingController(text: widget.initialSelector);
    _paginationUrl = TextEditingController();
    _page = widget.initialPage;
    _acquisition = widget.initialAcquisition;
    _savedSiteId = widget.savedSite?.id;

    final host = Uri.tryParse(widget.initialUrl)?.host ?? '';
    _siteName = TextEditingController(
      text: widget.savedSite?.name ?? (host.isEmpty ? '新しいサイト' : host),
    );

    final initial = widget.initialRule;
    if (initial != null) {
      _url.text = initial.pageUrl;
      _group.text = initial.groupSelector;
      _paginationUrl.text = initial.paginationUrl;
      _kind = initial.kind;
      _acquisition = initial.acquisition;
      _fields = Map.of(initial.fields);
      _details = Map.of(initial.details);
      _page = null;
      _status = '保存設定を開きました。HTML取得またはページから選択してください';
    }
  }

  ListExtractionRule _rule() => ListExtractionRule(
    pageUrl: _url.text.trim(),
    groupSelector: _group.text.trim(),
    paginationUrl: _kind == 'works' ? _paginationUrl.text.trim() : '',
    fields: Map.of(_fields),
    details: Map.of(_details),
    kind: _kind,
    acquisition: _acquisition,
  );

  Future<void> _editWorkDetails() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    final result = await Navigator.of(context).push<WorkDetailEditResult>(
      MaterialPageRoute<WorkDetailEditResult>(
        builder: (_) => WorkDetailsEditorPage(rule: _rule(), page: _page),
      ),
    );

    if (!mounted || result == null) return;
    setState(() {
      _details = Map.of(result.fields);
      if (result.page != null) {
        _page = result.page;
        _url.text = result.page!.uri.toString();
      }
      if (result.usedRenderedDom) _acquisition = 'renderedDom';
      _report = null;
      _status = '作品詳細設定を反映しました。「サイトに保存」で確定してください';
    });
  }

  void _invalidate() {
    setState(() => _report = null);
  }

  Future<void> _fetch() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final token = CancelToken();
    _cancel = token;

    setState(() {
      _busy = true;
      _report = null;
      _page = null;
      _status = 'HTMLを取得中';
    });

    try {
      final page = await _client.fetch(_url.text, cancelToken: token);
      if (!mounted) return;
      setState(() {
        _page = page;
        _url.text = page.uri.toString();
        _acquisition = 'staticHtml';
        _status = '通常HTMLを取得しました。テストしてください';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = ruleFailureMessage(error, stage: RuleDiagnosticStage.fetch);
        });
      }
    } finally {
      if (identical(_cancel, token)) _cancel = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickGroup() async {
    if (_busy) return;
    final pick = await Navigator.of(context).push<VisualPick>(
      MaterialPageRoute<VisualPick>(
        builder: (_) => ElementInspectorPage(url: _url.text),
      ),
    );

    if (!mounted || pick == null) return;
    setState(() {
      _page = pick.page;
      _url.text = pick.page.uri.toString();
      _group.text = pick.selector;
      _acquisition = 'renderedDom';
      _report = null;
      _status =
          '選択要素を「1件分のまとまり」にしました。'
          '複数件に一致する候補か確認してください';
    });
  }

  Future<void> _pickField(String key) async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    try {
      htmlProbeUri(_url.text);
      final group = _group.text.trim();
      if (group.isEmpty) {
        throw StateError('先に「1件分のまとまり」を指定してください');
      }

      final pick = await Navigator.of(context).push<VisualPick>(
        MaterialPageRoute<VisualPick>(
          builder: (_) => ElementInspectorPage(
            url: _url.text.trim(),
            groupSelector: group,
            fieldKey: key,
          ),
        ),
      );

      if (!mounted || pick == null) return;

      final next = listFieldFromPick(
        key: key,
        selector: pick.selector,
        mode: pick.mode,
        attribute: pick.attribute,
      );

      setState(() {
        _page = pick.page;
        _url.text = pick.page.uri.toString();
        _acquisition = 'renderedDom';
        _fields[key] = next.copyWith(
          pattern: _fields[key]!.pattern,
          replacement: _fields[key]!.replacement,
          localizeRelativeTime: _fields[key]!.localizeRelativeTime,
        );
        _revision++;
        _report = null;
        _status =
            '${listFieldLabels[key]}だけに選択結果を反映しました。'
            '「一覧としてテスト」で他のまとまりも確認してください';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '項目を選択できませんでした：$error');
      }
    }
  }

  Future<void> _test() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final page = _page;

    if (page == null) {
      setState(() => _status = 'HTML取得またはページから選択してください');
      return;
    }

    setState(() {
      _busy = true;
      _report = null;
      _status = '一覧をテスト中';
    });

    try {
      final report = await extractListRowsSafely(
        page,
        _rule(),
        collectCandidates: true,
      );
      if (!mounted) return;

      setState(() {
        _report = report;
        _status =
            '${report.total}件のまとまり／'
            '先頭${report.rows.length}件を表示\n'
            '取得元：$_acquisition'
            '${listReportAdvice(report, acquisition: _acquisition)}';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _report = null;
          _status = ruleFailureMessage(
            error,
            stage: RuleDiagnosticStage.extraction,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveSite() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);

    try {
      if (widget.onSaveRule != null) {
        final rule = _rule();
        rule.validate();

        if (rule.kind != 'works') {
          throw const FormatException('専用の一覧ルールは作品一覧として設定してください');
        }

        await widget.onSaveRule!(rule);

        if (mounted) {
          setState(() {
            markEditorSaved();
            _status =
                '専用の一覧設定を保存しました。'
                'この画面で保存は完了しています。追加の保存操作は不要です。';
          });
        }
        return;
      }

      final saved = await SiteRuleStore(
        widget.store.root,
      ).save(id: _savedSiteId, name: _siteName.text, rule: _rule());

      if (!mounted) return;
      setState(() {
        _savedSiteId = saved.id;
        _siteName.text = saved.name;
        markEditorSaved();
        _status =
            '「${saved.name}」の'
            '${_kind == 'works' ? '作品一覧' : 'チャプター一覧'}を保存しました。'
            '共有するときはサイト管理の「サイト一式のJSON・QR」を使用してください。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'サイトへ保存できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final rule = _rule();
      rule.validate();
      await widget.store.writeCache(_cacheKey, rule.toJson());
      if (mounted) setState(() => _status = '一覧ルールの下書きを保存しました');
    } catch (error) {
      if (mounted) setState(() => _status = '保存できませんでした：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      final data = await widget.store.readCache(_cacheKey);
      if (data == null) throw StateError('保存された下書きがありません');
      final rule = ListExtractionRule.parse(
        // JSON形式として再検証する。
        _encodeCache(data),
      );

      if (!mounted) return;
      final confirmed = await _confirm(
        '下書きを復元',
        '${rule.pageUrl}\n\n現在の編集内容を置き換えますか？',
      );
      if (confirmed && mounted) _apply(rule);
    } catch (error) {
      if (mounted) setState(() => _status = '復元できませんでした：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _encodeCache(dynamic data) => encodeListRuleCache(data);

  Future<bool> _confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('置き換える'),
            ),
          ],
        ),
      ) ??
      false;

  void _apply(ListExtractionRule rule) {
    if (widget.onSaveRule != null && rule.kind != 'works') {
      throw const FormatException('専用設定には作品一覧ルールを取り込んでください');
    }
    final samePage =
        _page?.uri.toString() == rule.pageUrl &&
        _acquisition == rule.acquisition;

    setState(() {
      if (!samePage) _page = null;
      _url.text = rule.pageUrl;
      _group.text = rule.groupSelector;
      _paginationUrl.text = rule.paginationUrl;
      _kind = rule.kind;
      _acquisition = rule.acquisition;
      _fields = Map.of(rule.fields);
      _details = Map.of(rule.details);
      _revision++;
      _report = null;
      _status = samePage
          ? '設定を反映しました。テストしてください'
          : '設定を反映しました。対象HTMLを取得、またはページから選択してください';
    });
  }

  Widget _fieldEditor(String key, String label) {
    final rule = _fields[key]!;
    final requiredField = key == 'title' || key == 'url';

    void update(ListFieldRule next) {
      setState(() {
        _fields[key] = next;
        _report = null;
      });
    }

    return ExpansionTile(
      key: ValueKey('$_revision:$key'),
      initiallyExpanded: requiredField,
      title: Text('$label${requiredField ? '（必須）' : ''}'),
      subtitle: Text(
        !rule.enabled
            ? '無効'
            : '${rule.selector.isEmpty ? '要素自身' : rule.selector}'
                  '／${rule.mode.name}'
                  '${rule.attribute.isEmpty ? '' : '：${rule.attribute}'}',
      ),
      childrenPadding: const EdgeInsets.all(12),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _pickField(key),
            icon: const Icon(Icons.ads_click),
            label: Text('$labelをまとまりから選ぶ'),
          ),
        ),
        const SizedBox(height: 12),
        if (!requiredField)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('この項目を取得する'),
            value: rule.enabled,
            onChanged: _busy
                ? null
                : (value) => update(rule.copyWith(enabled: value)),
          ),
        if (rule.enabled) ...[
          TextFormField(
            initialValue: rule.selector,
            enabled: !_busy,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '内側のセレクター',
              helperText: '空欄＝まとまりの要素自身。入力＝その内側。',
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                update(_fields[key]!.copyWith(selector: value)),
          ),
          const SizedBox(height: 12),
          if (key == 'date')
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('相対時間（英語）を日本語にする'),
              subtitle: const Text(
                '例：2 hours ago → 2時間前\n'
                '未対応の表示は変更しません。日時の計算や自動更新は行いません。',
              ),
              isThreeLine: true,
              value: rule.localizeRelativeTime,
              onChanged: _busy
                  ? null
                  : (value) => update(
                      _fields[key]!.copyWith(localizeRelativeTime: value),
                    ),
            ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: rule.pattern,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '正規表現（任意）',
              hintText: r'(\d+(?:\.\d+)?)',
              helperText: '空欄なら正規表現による整形なし。日本語化がONの場合は、その後の文字列に適用。',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                update(_fields[key]!.copyWith(pattern: value)),
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: rule.replacement,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '整形テンプレート',
              hintText: r'最新第$1話',
              helperText: r'$1・$2＝括弧の内容、$0＝一致全体、$$＝ドル記号。',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                update(_fields[key]!.copyWith(replacement: value)),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ListValueMode>(
            key: ValueKey('$_revision:$key:${rule.mode.name}'),
            initialValue: rule.mode,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '取得方法',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: ListValueMode.text, child: Text('文字列')),
              DropdownMenuItem(
                value: ListValueMode.attribute,
                child: Text('属性（href・srcなど）'),
              ),
              DropdownMenuItem(
                value: ListValueMode.cssUrl,
                child: Text('属性の中の最初の url(...)'),
              ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) {
                      update(
                        _fields[key]!.copyWith(
                          mode: value,
                          attribute: value == ListValueMode.cssUrl
                              ? 'style'
                              : _fields[key]!.attribute,
                        ),
                      );
                    }
                  },
          ),
          if (rule.mode != ListValueMode.text) ...[
            const SizedBox(height: 12),
            TextFormField(
              key: ValueKey('$_revision:$key:attr:${rule.mode.name}'),
              initialValue: rule.attribute,
              enabled: !_busy,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '属性名',
                hintText: 'href / src / data-src / style / id',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  update(_fields[key]!.copyWith(attribute: value)),
            ),
          ],
        ],
      ],
    );
  }

  Widget _resultCard(ExtractedListRow row, int index) {
    final values = row.values;
    final image = values['thumbnail'] ?? '';

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_showImages && image.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Image.network(
                  image,
                  height: 100,
                  width: 140,
                  fit: BoxFit.cover,
                  errorBuilder: (_, error, stack) => const SizedBox(
                    height: 100,
                    child: Center(child: Text('画像を表示できません')),
                  ),
                ),
              ),
            Text(
              '${index + 1}. ${values['title'] ?? ''}',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            for (final entry in values.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: SelectableText(
                  '${listFieldLabels[entry.key]}：'
                  '${entry.value.isEmpty ? '（空）' : entry.value}',
                ),
              ),
            if (row.matchCounts.isNotEmpty)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('一致候補・採用結果を確認'),
                subtitle: const Text('候補は加工前の値です。先頭を採用後、整形・URL解決を行います。'),
                children: [
                  for (final entry in row.matchCounts.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            '${listFieldLabels[entry.key]}：${entry.value}件一致',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 6),
                          for (
                            var i = 0;
                            i < (row.candidates[entry.key]?.length ?? 0);
                            i++
                          )
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: SelectableText(
                                '${i == 0 ? '✓ 採用候補' : '候補'} ${i + 1}：'
                                '${row.candidates[entry.key]![i].isEmpty ? '（空）' : row.candidates[entry.key]![i]}',
                              ),
                            ),
                          if (entry.value > 50) const Text('候補は先頭50件まで表示しています'),
                          if (entry.value == 0) const Text('一致する要素がありません'),
                          const SizedBox(height: 6),
                          SelectableText(
                            '最終結果：'
                            '${(values[entry.key] ?? '').isEmpty ? '（空）' : values[entry.key]}',
                            style: const TextStyle(color: Colors.tealAccent),
                          ),
                          const Divider(),
                        ],
                      ),
                    ),
                ],
              ),
            for (final issue in row.issues)
              Text(
                ruleIssueMessage(issue),
                style: const TextStyle(color: Colors.orangeAccent),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _cancel?.cancel('画面を閉じました');
    _client.close();
    _url.dispose();
    _group.dispose();
    _paginationUrl.dispose();
    _siteName.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => guardEditor(_buildEditor(context));

  Widget _buildEditor(BuildContext context) {
    final report = _report;

    return Scaffold(
      appBar: AppBar(
        leading: editorBackButton,
        title: Text(
          widget.onSaveRule != null
              ? '${widget.rulePurpose}の一覧ルール'
              : _savedSiteId == null
              ? '新規サイトルール作成'
              : '一覧ルール',
        ),
        actions: [
          IconButton(
            tooltip: '下書きを復元',
            onPressed: _busy ? null : _restore,
            icon: const Icon(Icons.restore),
          ),
          IconButton(
            tooltip: '下書きを保存',
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              '① 1作品／1話のまとまりを指定\n'
              '② 各項目を「要素自身」または「内側」から取得\n'
              '③ カードで組み合わせを確認',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _siteName,
              enabled: !_busy,
              maxLength: 100,
              decoration: const InputDecoration(
                labelText: 'サイト保存名',
                helperText: '保存ボタンで、現在選んでいる種類の一覧設定を保存します。',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _busy ? null : _saveSite,
                icon: const Icon(Icons.bookmark_add_outlined),
                label: const Text('サイトに保存'),
              ),
            ),
            const SizedBox(height: 16),
            RuleAcquisitionNotice(
              acquisition: _acquisition,
              pageAvailable:
                  _page != null && _page!.uri.toString() == _url.text.trim(),
              saveHint:
                  'この表示は現在の編集値です。'
                  '設定の変更は「サイトに保存」で確定します。'
                  '下書き保存だけではサイト設定は変更されません。',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '対象URL',
                helperText: '要素選択・テスト用の実際に開けるURLを指定します。',
                helperMaxLines: 2,
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _invalidate(),
            ),
            if (_kind == 'works') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _paginationUrl,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'ページ送りURL（任意）',
                  hintText: 'https://example.com/list?page={page;1}',
                  helperText:
                      '空欄＝ページ送りなし。{page;1}＝1から、{page;0}＝0から開始。\n'
                      '対象URLと同じ取得元を指定し、「サイトに保存」で確定します。',
                  helperMaxLines: 4,
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => _invalidate(),
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : _fetch,
                  child: const Text('通常HTMLを取得'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _pickGroup,
                  child: const Text('まとまりをページから選ぶ'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 3,
              child: _busy
                  ? const LinearProgressIndicator(minHeight: 3)
                  : const SizedBox.expand(),
            ),
            const SizedBox(height: 8),
            SelectableText(
              _status,
              style: const TextStyle(color: Colors.tealAccent),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('$_revision:$_kind'),
              initialValue: _kind,
              decoration: const InputDecoration(
                labelText: '一覧の種類',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'works', child: Text('作品一覧')),
                DropdownMenuItem(value: 'chapters', child: Text('チャプター一覧')),
              ],
              onChanged: _busy || widget.onSaveRule != null
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() {
                          _kind = value;
                          _report = null;
                        });
                      }
                    },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _group,
              enabled: !_busy,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '1件分のまとまり',
                hintText: '.comic-card / .chapter-row など',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => _invalidate(),
            ),
            const SizedBox(height: 12),
            if (_kind == 'chapters') ...[
              OutlinedButton.icon(
                onPressed: _busy ? null : _editWorkDetails,
                icon: const Icon(Icons.menu_book_outlined),
                label: const Text('作品詳細・並び替えを設定'),
              ),
              const SizedBox(height: 12),
            ],
            for (final entry in listFieldLabels.entries)
              _fieldEditor(entry.key, entry.value),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy ? null : _test,
              icon: const Icon(Icons.science_outlined),
              label: const Text('一覧としてテスト'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('表紙画像を通信して表示'),
              subtitle: const Text('有効にすると抽出した画像URLへアクセスします'),
              value: _showImages,
              onChanged: (value) => setState(() => _showImages = value),
            ),
            if (report != null) ...[
              Text(
                '${report.total}件に一致'
                '・先頭${report.rows.length}件を表示',
              ),
              for (var i = 0; i < report.rows.length; i++)
                _resultCard(report.rows[i], i),
            ],
            const SizedBox(height: 16),
            const Text(
              '下書きは端末内に1件保存します。復元は明示操作です。\n'
              '「サイトに保存」で現在の一覧設定を保存します。\n'
              '共有・取り込みはサイト管理の「サイト一式のJSON・QR」を使用してください。\n'
              '各項目の「まとまりから選ぶ」で内側を選択できます。セレクターの手入力も可能です。',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}
