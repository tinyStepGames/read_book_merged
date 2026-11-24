import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'editor_unsaved_changes.dart';
import 'element_inspector_page.dart';
import 'services/chapterless_work.dart';
import 'services/headless_download_page.dart';
import 'services/html_probe.dart';
import 'services/list_extraction_rule.dart';
import 'services/site_reading_settings.dart';
import 'services/site_rule_store.dart';
import 'work_details_editor_page.dart';

class SiteReadingEditorPage extends StatefulWidget {
  const SiteReadingEditorPage({
    super.key,
    required this.repository,
    required this.site,
  });

  final SiteRuleStore repository;
  final SavedSiteRule site;

  @override
  State<SiteReadingEditorPage> createState() => _SiteReadingEditorPageState();
}

class _SiteReadingEditorPageState extends State<SiteReadingEditorPage>
    with EditorUnsavedChanges<SiteReadingEditorPage> {
  late SiteReadingMode _mode;
  late final TextEditingController _sample;
  late final TextEditingController _selector;
  late final TextEditingController _attribute;
  late final TextEditingController _pattern;
  late final TextEditingController _replacement;

  ListExtractionRule? _details;
  HtmlProbePage? _page;
  late String _acquisition;
  late ListValueMode _linkMode;
  late bool _separateLink;

  final _probe = HtmlProbeClient();
  CancelToken? _cancel;
  bool _busy = false;
  String _status = '';

  @override
  void initState() {
    super.initState();

    final settings = widget.site.readingSettings;
    final link = settings?.readLink;

    _mode = widget.site.readingMode;
    _details = settings?.detailsRule;
    _sample = TextEditingController(
      text:
          _details?.pageUrl ??
          widget.site.images?.pageUrl ??
          widget.site.rules.values.first.pageUrl,
    );
    _selector = TextEditingController(text: link?.selector ?? '');
    _attribute = TextEditingController(text: link?.attribute ?? 'href');
    _pattern = TextEditingController(text: link?.pattern ?? '');
    _replacement = TextEditingController(text: link?.replacement ?? '');
    _acquisition = _details?.acquisition ?? 'staticHtml';
    _linkMode = link?.mode ?? ListValueMode.attribute;
    _separateLink = link != null;
  }

  @override
  List<TextEditingController> get editorInputs => [
    _sample,
    _selector,
    _attribute,
    _pattern,
    _replacement,
  ];

  @override
  bool get editorBusy => _busy;

  @override
  String get editorSnapshot => encodeEditorSnapshot({
    'mode': _mode.name,
    'sample': _sample.text,
    'details': _details?.toJson(),
    'acquisition': _acquisition,
    'separateLink': _separateLink,
    'linkMode': _linkMode.name,
    'selector': _selector.text,
    'attribute': _attribute.text,
    'pattern': _pattern.text,
    'replacement': _replacement.text,
  });

  @override
  void dispose() {
    _cancel?.cancel('画面を閉じました');
    _probe.close();
    for (final controller in editorInputs) {
      controller.dispose();
    }
    super.dispose();
  }

  ListExtractionRule _detailRule() => ListExtractionRule(
    pageUrl: _sample.text.trim(),
    groupSelector: 'html',
    fields: defaultListFields(),
    acquisition: _acquisition,
    details: {
      for (final entry
          in (_details?.details ?? const <String, ListFieldRule>{}).entries)
        if (entry.key != 'chapterNumber') entry.key: entry.value,
    },
  );

  SiteReadingSettings _settings() => SiteReadingSettings(
    mode: _mode,
    video: widget.site.readingSettings?.video,
    detailsRule: _mode == SiteReadingMode.details ? _detailRule() : null,
    readLink: _mode == SiteReadingMode.details && _separateLink
        ? ListFieldRule(
            selector: _selector.text.trim(),
            mode: _linkMode,
            attribute: _linkMode == ListValueMode.text
                ? ''
                : _attribute.text.trim(),
            pattern: _pattern.text,
            replacement: _replacement.text,
          )
        : null,
  );

  void _checkOrigin() {
    final origin = htmlProbeUri(_sample.text).origin;
    for (final rule in widget.site.rules.values) {
      if (htmlProbeUri(rule.pageUrl).origin != origin) {
        throw const FormatException('サンプルURLとサイトの取得元が異なります');
      }
    }
  }

  SavedSiteRule _previewSite(SiteReadingSettings settings) =>
      SavedSiteRule.fromJson({
        ...widget.site.toJson(),
        'readingSettings': settings.toJson(),
      });

  Future<void> _fetch() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    final token = CancelToken();
    _cancel = token;

    setState(() {
      _busy = true;
      _status = '通常HTMLを取得しています';
    });

    try {
      _checkOrigin();
      final target = htmlProbeUri(_sample.text);

      final page = await _probe.fetch(
        target.toString(),
        cancelToken: token,
        allowedOrigin: target.origin,
      );

      if (!mounted || token.isCancelled) return;

      if (htmlProbeUri(page.uri.toString()).origin != target.origin) {
        throw const FormatException('転送先の取得元が異なります');
      }

      setState(() {
        _page = page;
        _sample.text = page.uri.toString();
        _acquisition = 'staticHtml';
        _status = '通常HTMLを取得しました。作品詳細の項目を設定できます。';
      });
    } catch (error) {
      if (mounted && !token.isCancelled) {
        setState(() => _status = '取得できませんでした：$error');
      }
    } finally {
      if (mounted && identical(_cancel, token)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _editDetails() async {
    if (_busy) return;

    try {
      _checkOrigin();

      final page = _page;
      final matches =
          page != null &&
          page.uri.removeFragment() == htmlProbeUri(_sample.text);

      final result = await Navigator.of(context).push<WorkDetailEditResult>(
        MaterialPageRoute<WorkDetailEditResult>(
          builder: (_) => WorkDetailsEditorPage(
            rule: _detailRule(),
            page: matches ? page : null,
            chapterless: true,
          ),
        ),
      );

      if (!mounted || result == null) return;

      setState(() {
        if (result.page != null) {
          _page = result.page;
          _sample.text = result.page!.uri.toString();
        }

        if (result.usedRenderedDom) {
          _acquisition = 'renderedDom';
        }

        _details = ListExtractionRule(
          pageUrl: _sample.text.trim(),
          groupSelector: 'html',
          fields: defaultListFields(),
          acquisition: _acquisition,
          details: {
            for (final entry in result.fields.entries)
              if (entry.key != 'chapterNumber') entry.key: entry.value,
          },
        );

        _status = '作品詳細の設定を受け取りました。最後にこの画面で保存してください。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '編集できませんでした：$error');
      }
    }
  }

  Future<void> _pickLink() async {
    if (_busy) return;

    try {
      _checkOrigin();

      final pick = await Navigator.of(context).push<VisualPick>(
        MaterialPageRoute<VisualPick>(
          builder: (_) => ElementInspectorPage(
            url: _sample.text.trim(),
            groupSelector: '',
            fieldKey: '',
          ),
        ),
      );

      if (!mounted || pick == null) return;

      if (pick.mode == HtmlValueMode.innerHtml ||
          pick.attribute.toLowerCase() == 'style') {
        throw const FormatException('読むリンクはhref属性かURL文字列を選んでください');
      }

      setState(() {
        _selector.text = pick.selector.trim().isEmpty ? 'html' : pick.selector;
        _linkMode = pick.mode == HtmlValueMode.text
            ? ListValueMode.text
            : ListValueMode.attribute;
        _attribute.text = _linkMode == ListValueMode.text ? '' : pick.attribute;
        _page = pick.page;
        _sample.text = pick.page.uri.toString();
        _acquisition = 'renderedDom';
        _status = '読むリンクを反映しました。取得方式は表示後HTMLになります。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '選択できませんでした：$error');
      }
    }
  }

  Future<void> _test() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    final token = CancelToken();
    final client = ChapterlessWorkClient();
    _cancel = token;

    setState(() {
      _busy = true;
      _status = '作品詳細と読むリンクをテストしています';
    });

    try {
      final settings = _settings();
      settings.validateFor(widget.site.rules.values);

      final result = await client.load(
        site: _previewSite(settings),
        targetUrl: _sample.text.trim(),
        cancelToken: token,
        renderedFetcher:
            (
              input, {
              required cancelToken,
              required allowedOrigin,
              required groupSelector,
            }) => fetchRenderedDownloadPage(
              input,
              cancelToken: cancelToken,
              allowedOrigin: allowedOrigin,
              groupSelector: groupSelector,
            ),
      );

      if (!mounted || token.isCancelled) return;

      setState(() {
        _status = [
          'タイトル：${result.details.title.isEmpty ? '未取得（一覧のタイトルを使用）' : result.details.title}',
          '表紙：${result.details.thumbnail ?? '未取得（一覧の表紙を使用）'}',
          '説明：${result.details.description.isEmpty ? '未取得' : '取得済み'}',
          'タグ：${result.details.tags.length}件',
          '読むURL：${result.readUrl ?? '取得できませんでした'}',
          if (result.readIssue != null) result.readIssue!,
          ...result.details.issues,
          'テストでは本文画像の取得・保存は行っていません。',
        ].join('\n');
      });
    } catch (error) {
      if (mounted && !token.isCancelled) {
        setState(() => _status = 'テストできませんでした：$error');
      }
    } finally {
      client.close();
      if (mounted && identical(_cancel, token)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _save() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    try {
      final settings = _settings();
      settings.validateFor(widget.site.rules.values);

      setState(() {
        _busy = true;
        _status = '保存しています';
      });

      await widget.repository.saveReadingSettings(
        id: widget.site.id,
        settings: settings,
        expectedUpdatedAt: widget.site.updatedAt,
      );

      if (!mounted) return;

      setState(() {
        _busy = false;
        _status = '保存しました';
      });

      markEditorSaved();
      await requestEditorExit();
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _status = '保存できませんでした：$error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => guardEditor(
    Scaffold(
      appBar: AppBar(leading: editorBackButton, title: const Text('一覧からの開き方')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(widget.site.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          const Text(
            '通常一覧・タグ先・検索結果・サイト内タブに共通して適用します。'
            '保存するまではサイト設定を変更しません。',
          ),
          const SizedBox(height: 16),
          DropdownButtonFormField<SiteReadingMode>(
            key: ValueKey('reading-mode-${_mode.name}'),
            initialValue: _mode,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: '一覧の項目を押したとき',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final mode in SiteReadingMode.values)
                DropdownMenuItem(value: mode, child: Text(mode.label)),
            ],
            onChanged: _busy
                ? null
                : (value) {
                    if (value != null) {
                      setState(() => _mode = value);
                    }
                  },
          ),
          const SizedBox(height: 12),
          Text(switch (_mode) {
            SiteReadingMode.chapters => '作品一覧 → チャプター一覧 → 本文画像、の従来方式です。',
            SiteReadingMode.direct =>
              '一覧のリンク先ページから本文画像を取得します。'
                  'チャプター一覧ルールは不要です。本文画像ルールは必要です。',
            SiteReadingMode.details =>
              '一覧 → 作品詳細 → 読む、の順に開きます。'
                  'チャプター一覧ルールは不要です。',
          }),
          if (_mode == SiteReadingMode.details) ...[
            const SizedBox(height: 24),
            TextField(
              key: const ValueKey('reading-sample'),
              controller: _sample,
              enabled: !_busy,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: '作品詳細のサンプルURL',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() => _page = null),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: ValueKey('reading-acquisition-$_acquisition'),
              initialValue: _acquisition,
              decoration: const InputDecoration(
                labelText: '作品詳細の取得方式',
                border: OutlineInputBorder(),
              ),
              items: const [
                DropdownMenuItem(value: 'staticHtml', child: Text('通常HTML')),
                DropdownMenuItem(value: 'renderedDom', child: Text('表示後HTML')),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _acquisition = value);
                      }
                    },
            ),
            const SizedBox(height: 8),
            const Text(
              '要素選択を使うと「表示後HTML」になります。'
              '通常HTMLでも取得できる場合は、上で通常HTMLへ戻せます。',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _busy ? null : _fetch,
                  child: const Text('通常HTMLを取得'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _editDetails,
                  child: const Text('タイトル・表紙・説明・タグを設定'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('別の閲覧ページへのリンクを使う'),
              subtitle: Text(
                _separateLink
                    ? '詳細ページから「読む」リンクを1件抽出します。'
                    : '詳細ページ自体を本文画像の取得先にします。',
              ),
              value: _separateLink,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _separateLink = value),
            ),
            if (_separateLink) ...[
              TextField(
                key: const ValueKey('reading-link-selector'),
                controller: _selector,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: '読むリンクのCSSセレクター',
                  hintText: '例：a.read',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ListValueMode>(
                key: ValueKey('reading-link-mode-${_linkMode.name}'),
                initialValue: _linkMode,
                decoration: const InputDecoration(
                  labelText: 'URLの取得方法',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: ListValueMode.attribute,
                    child: Text('属性（通常はhref）'),
                  ),
                  DropdownMenuItem(
                    value: ListValueMode.text,
                    child: Text('文字列'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() => _linkMode = value);
                        }
                      },
              ),
              if (_linkMode == ListValueMode.attribute) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _attribute,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: '属性名',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  onPressed: _busy ? null : _pickLink,
                  child: const Text('ページから読むリンクを選ぶ'),
                ),
              ),
              ExpansionTile(
                title: const Text('読むURLの正規表現・整形'),
                children: [
                  TextField(
                    controller: _pattern,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: '正規表現'),
                  ),
                  TextField(
                    controller: _replacement,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: '整形テンプレート'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _busy ? null : _test,
              child: const Text('作品詳細・読むURLをテスト'),
            ),
          ],
          const SizedBox(height: 20),
          if (_status.isNotEmpty) ...[
            SelectableText(_status),
            const SizedBox(height: 16),
          ],
          FilledButton(
            key: const ValueKey('reading-settings-save'),
            onPressed: _busy ? null : _save,
            child: const Text('開き方を保存'),
          ),
          const SizedBox(height: 12),
          const Text(
            '本文画像の抽出設定は、サイトルール管理の「本文画像」で設定します。\n'
            '画像ファイルへの直リンクではなく、HTMLページ内の画像を読む方式です。\n'
            '別方式へ切り替えて保存すると、この画面の詳細・読むリンク設定は'
            'その方式に必要な設定へ置き換わります。'
            '既存のチャプター一覧ルールは削除しません。',
          ),
        ],
      ),
    ),
  );
}
