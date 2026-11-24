import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import 'rule_acquisition_notice.dart';

import 'editor_unsaved_changes.dart';
import 'package:flutter/services.dart';

import 'element_inspector_page.dart';
import 'services/chapter_image_probe.dart';
import 'services/chapter_image_rule.dart';
import 'services/html_probe.dart';
import 'services/site_rule_store.dart';
import 'services/chapter_image_settings.dart';

class ChapterImageLabPage extends StatefulWidget {
  const ChapterImageLabPage({
    super.key,
    required this.initialUrl,
    this.initialPage,
    this.initialAcquisition = 'staticHtml',
    this.repository,
    this.savedSite,
  });

  final String initialUrl;
  final HtmlProbePage? initialPage;
  final String initialAcquisition;
  final SiteRuleStore? repository;
  final SavedSiteRule? savedSite;

  @override
  State<ChapterImageLabPage> createState() => _ChapterImageLabPageState();
}

class _ChapterImageLabPageState extends State<ChapterImageLabPage>
    with EditorUnsavedChanges<ChapterImageLabPage> {
  @override
  bool get editorBusy => _busy;

  @override
  List<TextEditingController> get editorInputs => [_url, _selector, _attribute];

  @override
  String get editorSnapshot => encodeEditorSnapshot({
    'url': _url.text.trim(),
    'selector': _selector.text.trim(),
    'attribute': _attribute.text.trim(),
    'acquisition': _acquisition,
  });
  late final TextEditingController _url;
  final _selector = TextEditingController();
  final _attribute = TextEditingController(text: 'src');
  final _client = HtmlProbeClient();

  HtmlProbePage? _page;
  ChapterImageReport? _report;
  CancelToken? _cancel;
  bool _busy = false;
  int? _previewIndex;
  late String _acquisition;
  String _status = 'チャプターのURLからHTMLを取得してください。';

  @override
  void initState() {
    super.initState();
    _url = TextEditingController(text: widget.initialUrl);
    _page = widget.initialPage;
    _acquisition = widget.initialAcquisition;

    final saved = widget.savedSite?.images;
    if (saved != null) {
      _url.text = saved.pageUrl;
      _selector.text = saved.rule.selector;
      _attribute.text = saved.rule.attribute;
      _acquisition = saved.acquisition;

      // 前の画面から来たHTMLが保存設定のページとは限らないため破棄。
      _page = null;
      _status =
          '保存した本文画像ルールを復元しました。'
          'HTMLを取得し直してテストしてください。'
          '保存方式は${saved.acquisition == 'renderedDom' ? '表示後HTML' : '通常HTML'}です。';
    }

    if (_page != null) {
      _status =
          '作成室の取得済みHTMLを引き継ぎました。'
          'チャプター本文のページか確認してください。';
    }
  }

  void _clearResult({bool clearPage = false}) {
    setState(() {
      _report = null;
      _previewIndex = null;
      if (clearPage) {
        _page = null;
        _status = 'URLを変更しました。HTMLを取得し直してください。';
      }
    });
  }

  Future<void> _fetch() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    final token = CancelToken();
    _cancel = token;

    setState(() {
      _busy = true;
      _page = null;
      _report = null;
      _previewIndex = null;
      _status = '通常HTMLを取得しています…';
    });

    try {
      final input = htmlProbeUri(_url.text);
      final page = await _client.fetch(
        input.toString(),
        cancelToken: token,
        allowedOrigin: input.origin,
      );

      if (!mounted) return;
      setState(() {
        _page = page;
        _url.text = page.uri.toString();
        _acquisition = 'staticHtml';
        _status = '通常HTMLを取得しました。${page.bytes} bytes';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _status = token.isCancelled ? '取得を中止しました。' : 'HTMLを取得できませんでした：$error';
      });
    } finally {
      if (identical(_cancel, token)) _cancel = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pick() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();

    setState(() => _busy = true);

    try {
      final url = htmlProbeUri(_url.text).toString();
      final picked = await Navigator.of(context).push<VisualPick>(
        MaterialPageRoute<VisualPick>(
          builder: (_) => ElementInspectorPage(url: url),
        ),
      );

      if (!mounted || picked == null) return;

      if (picked.mode != HtmlValueMode.attribute) {
        setState(() {
          _status =
              '画像要素を選び、取得方法にsrc・data-srcなどの属性を'
              '指定してください。今回は反映していません。';
        });
        return;
      }

      final rule = ChapterImageRule(
        selector: picked.selector,
        attribute: picked.attribute,
      );
      rule.validate();

      setState(() {
        _url.text = picked.page.uri.toString();
        _page = picked.page;
        _selector.text = picked.selector;
        _attribute.text = picked.attribute;
        _acquisition = 'renderedDom';
        _report = null;
        _previewIndex = null;
        _status =
            '表示後HTMLと選択設定を反映しました。'
            '「画像URLを抽出」を押してください。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '選択設定を反映できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _extract() async {
    final page = _page;
    if (_busy || page == null) return;

    FocusScope.of(context).unfocus();

    setState(() {
      _busy = true;
      _report = null;
      _previewIndex = null;
      _status = '本文画像のURLを確認しています…';
    });

    try {
      final report = await probeChapterImages(
        page: page,
        rule: ChapterImageRule(
          selector: _selector.text.trim(),
          attribute: _attribute.text.trim(),
        ),
      );

      if (!mounted) return;
      setState(() {
        _report = report;
        _status = report.isUsable
            ? 'URL抽出に成功しました。次に画像の表示を確認してください。'
            : '抽出結果に問題があります。下の診断内容を確認してください。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = '画像URLを抽出できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToSite() async {
    final repository = widget.repository;
    final site = widget.savedSite;
    final page = _page;
    final report = _report;

    if (_busy ||
        repository == null ||
        site == null ||
        page == null ||
        report == null ||
        !report.isUsable) {
      return;
    }

    setState(() => _busy = true);

    try {
      final settings = ChapterImageSettings(
        pageUrl: page.uri.toString(),
        acquisition: _acquisition,
        rule: ChapterImageRule(
          selector: _selector.text.trim(),
          attribute: _attribute.text.trim(),
        ),
      );

      settings.validateOrigins(site.rules.values.map((rule) => rule.pageUrl));

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('本文画像ルールを保存'),
          content: SingleChildScrollView(
            child: Text(
              '保存先：${site.name}\n'
              '取得方式：${_acquisition == 'renderedDom' ? '表示後HTML' : '通常HTML'}\n'
              '画像URL：${report.images.length}件\n\n'
              '先頭・中央・最後が本文で、広告や抜けがないか確認しましたか？\n\n'
              'URL抽出の成功だけでは全ページの完全性を保証できません。\n'
              '同じサイトの別チャプターでも確認してください。\n\n'
              '保存するのはサンプルURL・取得方式・セレクター・属性です。'
              'HTML・画像・Cookieは保存しません。\n'
              '今回はまだリーダーには接続しません。',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('戻って確認'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('確認したので保存'),
            ),
          ],
        ),
      );

      if (!mounted || confirmed != true) return;

      await repository.saveImages(id: site.id, settings: settings);

      if (!mounted) return;
      setState(() {
        markEditorSaved();
        _status =
            '「${site.name}」に本文画像ルールを保存しました。'
            'リーダーへの接続は次の段階です。';
      });
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'サイトに保存できませんでした：$error');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyRule() async {
    try {
      final rule = ChapterImageRule(
        selector: _selector.text.trim(),
        attribute: _attribute.text.trim(),
      );
      await Clipboard.setData(ClipboardData(text: rule.encodeJson()));
      if (mounted) {
        setState(() {
          _status =
              '本文画像ルールのJSONをコピーしました。'
              '対象URLとHTMLの取得方式は、このJSONには含まれません。';
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() => _status = 'コピーできませんでした：$error');
      }
    }
  }

  Widget _preview(ChapterImageReport report) {
    if (report.images.isEmpty) return const SizedBox.shrink();

    final index = _previewIndex;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: _busy ? null : () => setState(() => _previewIndex = 0),
              child: const Text('先頭を確認'),
            ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => setState(
                      () => _previewIndex = report.images.length ~/ 2,
                    ),
              child: const Text('中央を確認'),
            ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => setState(
                      () => _previewIndex = report.images.length - 1,
                    ),
              child: const Text('最後を確認'),
            ),
          ],
        ),
        if (index != null) ...[
          const SizedBox(height: 12),
          Text('画像 ${index + 1} / ${report.images.length}'),
          const SizedBox(height: 8),
          SizedBox(
            height: 420,
            child: Image.network(
              report.images[index].toString(),
              key: ValueKey(report.images[index].toString()),
              fit: BoxFit.contain,
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return const Center(child: CircularProgressIndicator());
              },
              errorBuilder: (_, error, stack) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    'この画像を表示できませんでした。\n'
                    'URLの有効期限・アクセス条件・通信状態などを確認してください。\n'
                    '$error',
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          SelectableText(
            report.images[index].toString(),
            style: const TextStyle(fontSize: 12, color: Colors.white60),
          ),
        ],
      ],
    );
  }

  @override
  void dispose() {
    _cancel?.cancel('画面終了');
    _client.close();
    _url.dispose();
    _selector.dispose();
    _attribute.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => guardEditor(_buildEditor(context));

  Widget _buildEditor(BuildContext context) {
    final report = _report;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        leading: editorBackButton,
        title: const Text('本文画像テスト'),
        actions: [
          IconButton(
            tooltip: '本文画像ルールのJSONをコピー',
            onPressed: !_busy && report?.isUsable == true ? _copyRule : null,
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      widget.savedSite == null
                          ? '本文画像の抽出順と表示を確認します。'
                                'サイトへ保存する場合は、サイトルール管理の'
                                '「本文画像」から開いてください。'
                          : '保存先：${widget.savedSite!.name}\n'
                                '抽出と画像表示を確認後、本文画像ルールを保存できます。'
                                '今回はリーダー接続・画像保存は行いません。',
                      style: TextStyle(color: Colors.white60),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _url,
                      enabled: !_busy,
                      keyboardType: TextInputType.url,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'チャプター本文のURL',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => _clearResult(clearPage: true),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _busy ? null : _fetch,
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('通常HTML取得'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _pick,
                          icon: const Icon(Icons.ads_click),
                          label: const Text('ページから選ぶ'),
                        ),
                        if (_cancel != null)
                          TextButton(
                            onPressed: () => _cancel?.cancel('利用者が中止'),
                            child: const Text('取得を中止'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    RuleAcquisitionNotice(
                      acquisition: _acquisition,
                      pageAvailable:
                          _page != null &&
                          _page!.uri.toString() == _url.text.trim(),
                      saveHint:
                          widget.repository != null && widget.savedSite != null
                          ? 'この表示は現在の編集値です。'
                                '画像URLの抽出と表示を確認し、'
                                '「本文画像ルールをサイトに保存」で確定します。'
                          : 'この画面では抽出を確認できます。'
                                'サイトへ保存する場合は、'
                                'サイト管理の「本文画像」から開いてください。',
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _selector,
                      enabled: !_busy,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: '本文画像のCSSセレクター',
                        hintText: '.reader img',
                        helperText: '表紙・広告を含まない本文画像の範囲を指定します。',
                        helperMaxLines: 2,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => _clearResult(),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _attribute,
                      enabled: !_busy,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: '画像URLの属性',
                        hintText: 'src または data-src など',
                        helperText: '1つの画像URLが入る属性を指定します。',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (_) => _clearResult(),
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _busy || _page == null ? null : _extract,
                      icon: const Icon(Icons.image_search),
                      label: const Text('画像URLを抽出'),
                    ),
                    const SizedBox(height: 12),
                    if (_busy) ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 12),
                    ],
                    SelectableText(_status),
                    if (widget.repository != null &&
                        widget.savedSite != null) ...[
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: !_busy && report?.isUsable == true
                            ? _saveToSite
                            : null,
                        icon: const Icon(Icons.save_outlined),
                        label: const Text('本文画像ルールをサイトに保存'),
                      ),
                    ],
                    if (report != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        '一致 ${report.matchedCount}件 ／ '
                        '画像URL ${report.images.length}件 ／ '
                        '重複 ${report.duplicateCount}件 ／ '
                        '問題 ${report.issues.length}件',
                      ),
                      if (report.issues.isNotEmpty)
                        ExpansionTile(
                          title: const Text(
                            '診断内容（先頭20件）',
                            style: TextStyle(color: Colors.orangeAccent),
                          ),
                          children: [
                            for (final issue in report.issues.take(20))
                              Padding(
                                padding: const EdgeInsets.all(8),
                                child: SelectableText(issue),
                              ),
                          ],
                        ),
                      const SizedBox(height: 8),
                      const Text(
                        '画像は選んだ1枚だけ読み込みます。'
                        '先頭・中央・最後が本文か確認してください。\n'
                        'URL抽出の成功は、画像の取得成功や全ページの完全性を'
                        '保証するものではありません。',
                        style: TextStyle(fontSize: 12, color: Colors.white60),
                      ),
                      _preview(report),
                      const SizedBox(height: 20),
                      const Text(
                        '抽出順の画像URL',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (report != null)
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (context, index) => ListTile(
                    leading: SizedBox(width: 48, child: Text('${index + 1}')),
                    title: Text(
                      report.images[index].toString(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: const Icon(Icons.image_outlined),
                    onTap: _busy
                        ? null
                        : () => setState(() => _previewIndex = index),
                  ),
                  childCount: report.images.length,
                ),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 32)),
          ],
        ),
      ),
    );
  }
}
