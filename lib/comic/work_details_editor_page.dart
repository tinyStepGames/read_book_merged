import 'package:flutter/material.dart';

import 'rule_acquisition_notice.dart';

import 'editor_unsaved_changes.dart';

import 'element_inspector_page.dart';
import 'services/html_probe.dart';
import 'services/list_extraction_rule.dart';
import 'services/work_page_details.dart';

class WorkDetailEditResult {
  const WorkDetailEditResult(this.fields, this.page, this.usedRenderedDom);

  final Map<String, ListFieldRule> fields;
  final HtmlProbePage? page;
  final bool usedRenderedDom;
}

class WorkDetailsEditorPage extends StatefulWidget {
  const WorkDetailsEditorPage({
    super.key,
    required this.rule,
    required this.page,
    this.chapterless = false,
  });

  final ListExtractionRule rule;
  final HtmlProbePage? page;
  final bool chapterless;

  @override
  State<WorkDetailsEditorPage> createState() => _WorkDetailsEditorPageState();
}

class _WorkDetailsEditorPageState extends State<WorkDetailsEditorPage>
    with EditorUnsavedChanges<WorkDetailsEditorPage> {
  @override
  bool get editorBusy => _busy;

  @override
  String get editorSnapshot => encodeEditorSnapshot({
    'pageUrl': _page?.uri.toString() ?? widget.rule.pageUrl,
    'acquisition': _usedRenderedDom ? 'renderedDom' : widget.rule.acquisition,
    'fields': {
      for (final entry in _fields.entries) entry.key: entry.value.toJson(),
    },
  });
  late Map<String, ListFieldRule> _fields;
  HtmlProbePage? _page;
  WorkPageDetails? _preview;
  bool _busy = false;
  bool _usedRenderedDom = false;
  int _revision = 0;
  String _status = 'タイトル・表紙・説明・タグはページ全体から取得します。';

  @override
  void initState() {
    super.initState();
    _page = widget.page;
    _fields = {
      for (final key in workDetailLabels.keys)
        key:
            widget.rule.details[key] ??
            ListFieldRule(
              enabled: false,
              mode: key == 'thumbnail'
                  ? ListValueMode.attribute
                  : ListValueMode.text,
              attribute: key == 'thumbnail' ? 'src' : '',
            ),
    };
  }

  Map<String, ListFieldRule> get _enabledFields => {
    for (final entry in _fields.entries)
      if (entry.value.enabled) entry.key: entry.value,
  };

  ListExtractionRule _rule() => ListExtractionRule(
    pageUrl: (_page?.uri.toString() ?? widget.rule.pageUrl),
    groupSelector: widget.rule.groupSelector,
    fields: Map.of(widget.rule.fields),
    kind: widget.rule.kind,
    acquisition: _usedRenderedDom ? 'renderedDom' : widget.rule.acquisition,
    details: _enabledFields,
  );

  void _update(String key, ListFieldRule field) {
    setState(() {
      _fields[key] = field;
      _preview = null;
    });
  }

  Future<void> _pick(String key) async {
    if (_busy) return;

    try {
      final number = key == 'chapterNumber';
      final pick = await Navigator.of(context).push<VisualPick>(
        MaterialPageRoute<VisualPick>(
          builder: (_) => ElementInspectorPage(
            url: _page?.uri.toString() ?? widget.rule.pageUrl,
            groupSelector: number ? widget.rule.groupSelector : '',
            fieldKey: number ? 'title' : '',
          ),
        ),
      );

      if (!mounted || pick == null) return;
      if (pick.mode == HtmlValueMode.innerHtml) {
        throw const FormatException('文字列または属性を選んでください');
      }

      final current = _fields[key]!;
      final isText = pick.mode == HtmlValueMode.text;
      final selector = pick.selector.trim().isEmpty
          ? (number ? ':scope' : 'html')
          : pick.selector;

      setState(() {
        _page = pick.page;
        _usedRenderedDom = true;
        _fields[key] = current.copyWith(
          enabled: true,
          selector: selector,
          mode: isText
              ? ListValueMode.text
              : pick.attribute.toLowerCase() == 'style'
              ? ListValueMode.cssUrl
              : ListValueMode.attribute,
          attribute: isText ? '' : pick.attribute,
        );
        _revision++;
        _preview = null;
        _status = '${workDetailLabels[key]}に選択結果を反映しました。テストしてください。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '選択できませんでした：$error');
      }
    }
  }

  Future<void> _test() async {
    if (_busy) return;
    final page = _page;
    if (page == null) {
      setState(() {
        _status = '前の画面で通常HTMLを取得するか、この画面の「ページから選ぶ」を使用してください。';
      });
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _preview = null;
      _status = '作品詳細をテスト中';
    });

    try {
      final result = await extractWorkPageDetailsSafely(page, _rule());
      if (!mounted) return;
      setState(() {
        _preview = result;
        _status = 'テストが完了しました。取得結果と注意事項を確認してください。';
      });
    } catch (error) {
      if (mounted) setState(() => _status = 'テストできませんでした：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    if (_busy) return;

    try {
      _rule().validate();
      await applyEditorResult(
        WorkDetailEditResult(_enabledFields, _page, _usedRenderedDom),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _status = '設定を反映できませんでした：$error');
      }
    }
  }

  Widget _editor(String key, String label) {
    final field = _fields[key]!;
    final number = key == 'chapterNumber';

    return ExpansionTile(
      key: ValueKey('$_revision:$key'),
      title: Text(label),
      subtitle: Text(field.enabled ? field.selector : '未設定'),
      childrenPadding: const EdgeInsets.all(12),
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('取得する'),
          value: field.enabled,
          onChanged: _busy
              ? null
              : (value) => _update(key, _fields[key]!.copyWith(enabled: value)),
        ),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _pick(key),
          icon: const Icon(Icons.ads_click),
          label: Text(number ? '1話のまとまりから選ぶ' : 'ページ全体から選ぶ'),
        ),
        if (field.enabled) ...[
          const SizedBox(height: 12),
          TextFormField(
            initialValue: field.selector,
            enabled: !_busy,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: number ? '1話の内側のセレクター' : 'ページ全体からのセレクター',
              helperText: number
                  ? '例：a.chapter-title。まとまり自身は :scope'
                  : key == 'tags'
                  ? '1タグずつのa要素を推奨。文字列で名前を取得し、hrefは自動取得します。例：.genres a'
                  : '例：h1[lang="ja"] / .description / img.cover',
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) =>
                _update(key, _fields[key]!.copyWith(selector: value)),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<ListValueMode>(
            initialValue: field.mode,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '取得方法',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: ListValueMode.text, child: Text('文字列')),
              DropdownMenuItem(
                value: ListValueMode.attribute,
                child: Text('属性'),
              ),
              DropdownMenuItem(
                value: ListValueMode.cssUrl,
                child: Text('属性内の url(...)'),
              ),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value == null) return;
                    _update(
                      key,
                      _fields[key]!.copyWith(
                        mode: value,
                        attribute: value == ListValueMode.cssUrl
                            ? 'style'
                            : _fields[key]!.attribute,
                      ),
                    );
                  },
          ),
          if (field.mode != ListValueMode.text) ...[
            const SizedBox(height: 12),
            TextFormField(
              key: ValueKey('$_revision:$key:${field.mode.name}:attribute'),
              initialValue: field.attribute,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: '属性名',
                hintText: 'src / data-src / style / content',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) =>
                  _update(key, _fields[key]!.copyWith(attribute: value)),
            ),
          ],
          const SizedBox(height: 12),
          TextFormField(
            initialValue: field.pattern,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: '正規表現（任意）',
              hintText: number
                  ? r'(?:第\s*|Chapter\s*)(\d+(?:\.\d+)?)'
                  : r'日本語[：:]\s*([^\r\n]+)',
              helperText:
                  '空欄なら加工しません。複数行も対象にする場合は '
                  r'[\s\S] などを使います。',
              helperMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
            onChanged: (value) =>
                _update(key, _fields[key]!.copyWith(pattern: value)),
          ),
          const SizedBox(height: 12),
          TextFormField(
            initialValue: field.replacement,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: '整形テンプレート',
              hintText: r'$1',
              helperText:
                  r'$1＝1つ目の括弧、$0＝一致全体。'
                  '正規表現を使う場合は指定してください。',
              helperMaxLines: 3,
              border: OutlineInputBorder(),
            ),
            onChanged: (value) =>
                _update(key, _fields[key]!.copyWith(replacement: value)),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => guardEditor(_buildEditor(context));

  Widget _buildEditor(BuildContext context) {
    final preview = _preview;

    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          leading: editorBackButton,
          title: Text(widget.chapterless ? '作品詳細の設定' : '作品詳細・並び替え'),
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'タイトル・表紙・説明・タグは作品ページ全体から抽出します。\n'
                '並び替え用の話数だけは、1話ずつのまとまりから抽出します。\n'
                '要素選択を使用すると、取得方式は「表示後HTML」になります。',
              ),
              const SizedBox(height: 12),
              RuleAcquisitionNotice(
                title: '親画面へ反映する取得方式',
                acquisition: _usedRenderedDom
                    ? 'renderedDom'
                    : widget.rule.acquisition,
                pageAvailable: _page != null,
                canFetchStaticHere: false,
                saveHint:
                    '「設定を反映して戻る」で前の一覧設定へ渡します。'
                    'その後、一覧設定の「サイトに保存」で確定します。',
              ),
              const SizedBox(height: 12),
              for (final entry in workDetailLabels.entries)
                if (!widget.chapterless || entry.key != 'chapterNumber')
                  _editor(entry.key, entry.value),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _busy ? null : _test,
                icon: const Icon(Icons.science_outlined),
                label: const Text('作品詳細をテスト'),
              ),
              const SizedBox(height: 12),
              if (_busy) const LinearProgressIndicator(),
              SelectableText(_status),
              if (preview != null) ...[
                const Divider(height: 32),
                const Text('取得結果'),
                const SizedBox(height: 12),
                SelectableText('タイトル：${preview.title}'),
                const SizedBox(height: 8),
                SelectableText('表紙URL：${preview.thumbnail ?? ''}'),
                const SizedBox(height: 8),
                SelectableText('説明：\n${preview.description}'),
                const SizedBox(height: 8),
                SelectableText('タグ：${preview.tags.join(' ／ ')}'),
                for (final link in preview.tagLinks)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: SelectableText(
                      '${link.label} → ${link.url}',
                      style: const TextStyle(color: Colors.lightBlueAccent),
                    ),
                  ),
                const SizedBox(height: 8),
                SelectableText(
                  '並び替え用話数（先頭30件）：\n'
                  '${preview.chapterNumbers.take(30).map((value) => value.isEmpty ? '（空）' : value).join(' ／ ')}',
                ),
                for (final issue in preview.issues)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      issue,
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                onPressed: _busy ? null : _apply,
                child: const Text('設定を反映して戻る'),
              ),
              const SizedBox(height: 8),
              const Text(
                '戻った画面で「サイトに保存」を押すと確定します。\n'
                '正規表現による整形対象は既存仕様と同じ4,096文字までです。',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
