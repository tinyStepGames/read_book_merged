import 'list_rule_lab_page.dart';
import 'site_rules_page.dart';
import 'element_inspector_page.dart';
import 'extraction_rule_transfer.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/download_store.dart';
import 'services/html_probe.dart';
import 'chapter_image_lab_page.dart';

class HtmlRuleLabPage extends StatefulWidget {
  const HtmlRuleLabPage({super.key, required this.store});

  final DownloadStore store;

  @override
  State<HtmlRuleLabPage> createState() => _HtmlRuleLabPageState();
}

class _HtmlRuleLabPageState extends State<HtmlRuleLabPage> {
  static const _draftKey = 'rule-lab:draft:v1';

  final _url = TextEditingController(
    text: 'https://www.peppercarrot.com/ja/webcomics/peppercarrot.html',
  );
  final _selector = TextEditingController(text: 'figcaption a');
  final _attribute = TextEditingController(text: 'href');
  final _client = HtmlProbeClient();

  HtmlValueMode _mode = HtmlValueMode.attribute;
  bool _resolveUrls = true;
  String _acquisition = 'staticHtml';
  bool _busy = true;
  String _status = '下書きを確認中';
  HtmlProbePage? _page;
  HtmlProbeResult? _result;
  List<String> _sourceLines = [];
  int _totalSourceLines = 0;
  CancelToken? _cancelToken;

  @override
  void initState() {
    super.initState();
    _loadDraft();
  }

  Future<void> _loadDraft() async {
    try {
      final data = await widget.store.readCache(_draftKey);
      if (!mounted) return;

      if (data is Map && data['version'] == 1) {
        _url.text = data['url'] as String? ?? _url.text;
        _selector.text = data['selector'] as String? ?? '';
        _attribute.text = data['attribute'] as String? ?? 'href';
        _resolveUrls = data['resolveUrls'] != false;
        _acquisition = data['acquisition'] == 'renderedDom'
            ? 'renderedDom'
            : 'staticHtml';

        final mode = data['mode'];
        for (final candidate in HtmlValueMode.values) {
          if (candidate.name == mode) _mode = candidate;
        }
      }

      _status = 'URLを入力して「HTML取得」を押してください';
    } catch (error) {
      _status = '下書きを復元できませんでした：$error';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openVisual() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    final selected = await Navigator.of(context).push<VisualPick>(
      MaterialPageRoute<VisualPick>(
        builder: (_) => ElementInspectorPage(url: _url.text),
      ),
    );

    if (!mounted || selected == null) return;
    final lines = selected.page.source.split('\n');

    setState(() {
      _url.text = selected.page.uri.toString();
      _selector.text = selected.selector;
      _attribute.text = selected.attribute;
      _mode = selected.mode;
      _page = selected.page;
      _sourceLines = lines.take(2000).toList();
      _totalSourceLines = lines.length;
      _result = null;
      _acquisition = 'renderedDom';
      _status =
          '表示後DOMと選択設定を反映しました。\n'
          '「抽出テスト」で確認してください';
    });
  }

  Future<void> _openChapterImageLab() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChapterImageLabPage(
          initialUrl: _page?.uri.toString() ?? _url.text,
          initialPage: _page,
          initialAcquisition: _acquisition,
        ),
      ),
    );
  }

  Future<void> _openSiteRules() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SiteRulesPage(store: widget.store),
      ),
    );
  }

  Future<void> _openListRule() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ListRuleLabPage(
          store: widget.store,
          initialPage: _page,
          initialUrl: _page?.uri.toString() ?? _url.text,
          initialSelector: _selector.text,
          initialAcquisition: _acquisition,
        ),
      ),
    );
  }

  Future<void> _openTransfer() async {
    if (_busy) return;

    try {
      final draft = ExtractionDraft(
        pageUrl: _page?.uri.toString() ?? _url.text,
        selector: _selector.text,
        attribute: _attribute.text,
        mode: _mode,
        resolveUrls: _resolveUrls,
        acquisition: _acquisition,
      );
      draft.validate();

      final imported = await Navigator.of(context).push<ExtractionDraft>(
        MaterialPageRoute<ExtractionDraft>(
          builder: (_) => ExtractionTransferPage(draft: draft),
        ),
      );

      if (!mounted || imported == null) return;

      setState(() {
        _url.text = imported.pageUrl;
        _selector.text = imported.selector;
        _attribute.text = imported.attribute;
        _mode = imported.mode;
        _resolveUrls = imported.resolveUrls;
        _acquisition = imported.acquisition;
        _page = null;
        _result = null;
        _sourceLines = [];
        _totalSourceLines = 0;
        _status = imported.acquisition == 'renderedDom'
            ? '設定を取り込みました。'
                  '「ページから選ぶ」で対象ページを確認してください'
            : '設定を取り込みました。「HTML取得」で確認してください';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '共有設定を開けませんでした：$error');
      }
    }
  }

  Future<void> _saveDraft() async {
    if (_busy) return;
    setState(() => _busy = true);

    try {
      await widget.store.writeCache(_draftKey, {
        'version': 1,
        'url': _url.text,
        'selector': _selector.text,
        'attribute': _attribute.text,
        'mode': _mode.name,
        'resolveUrls': _resolveUrls,
        'acquisition': _acquisition,
      });

      if (mounted) setState(() => _status = '下書きを端末に保存しました');
    } catch (error) {
      if (mounted) {
        setState(() => _status = '保存できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _fetch() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    final token = CancelToken();
    _cancelToken = token;

    setState(() {
      _busy = true;
      _page = null;
      _result = null;
      _sourceLines = [];
      _totalSourceLines = 0;
      _status = 'HTMLを取得中';
    });

    try {
      final page = await _client.fetch(_url.text, cancelToken: token);

      if (!mounted) return;
      final lines = page.source.split('\n');

      setState(() {
        _page = page;
        _acquisition = 'staticHtml';
        _sourceLines = lines.take(2000).toList();
        _totalSourceLines = lines.length;
        _status =
            '取得成功：${page.bytes} bytes\n'
            '${page.uri}';
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = token.isCancelled
              ? '取得を中止しました：${token.cancelError?.message ?? ''}'
              : '取得できませんでした：$error';
        });
      }
    } finally {
      if (identical(_cancelToken, token)) _cancelToken = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  void _extract() {
    final page = _page;
    if (page == null || _busy) return;
    FocusScope.of(context).unfocus();

    try {
      final result = extractProbeValues(
        page: page,
        selector: _selector.text,
        mode: _mode,
        attribute: _attribute.text,
        resolveUrls: _resolveUrls,
      );

      setState(() {
        _result = result;
        _status =
            '${result.matchedCount}件に一致・'
            '${result.values.length}件を表示\n'
            '空欄は属性がない、または値が空です';
      });
    } catch (error) {
      setState(() {
        _result = null;
        _status = '抽出できませんでした：$error';
      });
    }
  }

  Future<void> _copy(String value) async {
    try {
      await Clipboard.setData(ClipboardData(text: value));
      if (mounted) setState(() => _status = 'コピーしました');
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'コピーできませんでした：$error');
      }
    }
  }

  String _short(String value, int limit) => value.length <= limit
      ? value
      : '${value.substring(0, limit)}\n…表示省略（コピーは全文）';

  @override
  void dispose() {
    _cancelToken?.cancel('画面を閉じました');
    _client.close();
    _url.dispose();
    _selector.dispose();
    _attribute.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final page = _page;

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          title: const Text('HTMLルール作成室'),
          actions: [
            IconButton(
              tooltip: '本文画像テスト',
              onPressed: _busy ? null : _openChapterImageLab,
              icon: const Icon(Icons.collections_outlined),
            ),
            IconButton(
              tooltip: '下書きを保存',
              onPressed: _busy ? null : _saveDraft,
              icon: const Icon(Icons.save_outlined),
            ),
          ],
        ),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'URLからHTMLを取得し、外部ブラウザーを開かずに抽出を試せます。\n'
                '初版：HTTPS・UTF-8・通常HTML／最大2MiB',
                style: TextStyle(color: Colors.white60),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _url,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: '取得するURL',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _openSiteRules,
                    icon: const Icon(Icons.folder_outlined),
                    label: const Text('サイトルール管理'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _openListRule,
                    icon: const Icon(Icons.view_list_outlined),
                    label: const Text('一覧ルール'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _openVisual,
                    icon: const Icon(Icons.ads_click),
                    label: const Text('ページから選ぶ'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _openTransfer,
                    icon: const Icon(Icons.qr_code),
                    label: const Text('JSON・QR'),
                  ),
                  FilledButton.icon(
                    onPressed: _busy ? null : _fetch,
                    icon: const Icon(Icons.download),
                    label: const Text('HTML取得'),
                  ),
                  if (_cancelToken != null)
                    OutlinedButton(
                      onPressed: () => _cancelToken?.cancel('手動中止'),
                      child: const Text('取得中止'),
                    ),
                  OutlinedButton.icon(
                    onPressed: page == null ? null : () => _copy(page.source),
                    icon: const Icon(Icons.copy),
                    label: const Text('HTML全文コピー'),
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
                style: const TextStyle(color: Colors.tealAccent, fontSize: 13),
              ),
              if (page != null) ...[
                const SizedBox(height: 8),
                Text(
                  '抽出対象：${page.uri}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
              const SizedBox(height: 16),
              TextField(
                controller: _selector,
                enabled: !_busy,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'CSSセレクター',
                  hintText: '例：figcaption a / .webcomic-page img',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<HtmlValueMode>(
                key: ValueKey(_mode),
                initialValue: _mode,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: '取得する値',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(
                    value: HtmlValueMode.text,
                    child: Text('文字列（text）'),
                  ),
                  DropdownMenuItem(
                    value: HtmlValueMode.innerHtml,
                    child: Text('内側のHTML（innerHTML）'),
                  ),
                  DropdownMenuItem(
                    value: HtmlValueMode.attribute,
                    child: Text('属性（href・srcなど）'),
                  ),
                ],
                onChanged: _busy
                    ? null
                    : (value) {
                        if (value != null) {
                          setState(() {
                            _mode = value;
                            _result = null;
                          });
                        }
                      },
              ),
              if (_mode == HtmlValueMode.attribute) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _attribute,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '属性名',
                    hintText: 'href / src / data-src / style など',
                    border: OutlineInputBorder(),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('相対URLを絶対URLへ変換'),
                  subtitle: const Text('href・src・data-src・posterが対象'),
                  value: _resolveUrls,
                  onChanged: _busy
                      ? null
                      : (value) {
                          setState(() {
                            _resolveUrls = value;
                            _result = null;
                          });
                        },
                ),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: page == null || _busy ? null : _extract,
                icon: const Icon(Icons.science_outlined),
                label: const Text('抽出テスト'),
              ),
              const SizedBox(height: 16),
              const TabBar(
                tabs: [
                  Tab(text: '抽出結果'),
                  Tab(text: 'HTMLソース'),
                ],
              ),
              SizedBox(
                height: 340,
                child: TabBarView(
                  children: [
                    result == null
                        ? const Center(child: Text('抽出テストを実行してください'))
                        : result.values.isEmpty
                        ? const Center(child: Text('一致する要素はありません'))
                        : ListView.separated(
                            itemCount: result.values.length,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final value = result.values[index];

                              return Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Text('${index + 1}'),
                                        const Spacer(),
                                        IconButton(
                                          tooltip: '値をコピー',
                                          onPressed: () => _copy(value),
                                          icon: const Icon(
                                            Icons.copy,
                                            size: 18,
                                          ),
                                        ),
                                      ],
                                    ),
                                    SelectableText(
                                      value.isEmpty
                                          ? '（空）'
                                          : _short(value, 4000),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                    page == null
                        ? const Center(child: Text('HTMLを取得してください'))
                        : Column(
                            children: [
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: Text(
                                  '$_totalSourceLines行'
                                  '・画面表示は先頭2000行／各行4000文字まで\n'
                                  '全文は「HTML全文コピー」で取得できます',
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: ListView.builder(
                                  itemCount: _sourceLines.length,
                                  itemBuilder: (context, index) => Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 2,
                                    ),
                                    child: SelectableText(
                                      '${index + 1}: '
                                      '${_short(_sourceLines[index], 4000)}',
                                      style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '下書き保存の対象はURLと抽出設定のみです。'
                'HTML本文は端末ファイルへ保存しません。\n'
                'srcsetやstyle内のurl(...)の解析、正規表現置換、'
                'サイトとしての登録は次の段階で追加します。',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
