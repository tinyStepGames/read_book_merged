import 'package:flutter/material.dart';

import 'rule_browse_page.dart';
import 'services/site_rule_store.dart';
import 'services/site_search_plan.dart';
import 'services/site_search_settings.dart';

class SiteSearchPage extends StatefulWidget {
  const SiteSearchPage({super.key, required this.site});

  final SavedSiteRule site;

  @override
  State<SiteSearchPage> createState() => _SiteSearchPageState();
}

class _SiteSearchPageState extends State<SiteSearchPage> {
  final _query = TextEditingController();
  bool _opening = false;
  String _error = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    if (_opening) return;
    FocusScope.of(context).unfocus();

    try {
      final settings = widget.site.searchSettings;
      if (settings == null) {
        throw const FormatException('サイト管理から検索設定を追加してください');
      }

      final keyword = normalizeSiteSearchKeyword(
        _query.text,
        normalizeSpaces: settings.normalizeSpaces,
      );

      final plan = makeSiteSearchPlan(widget.site, keyword);

      setState(() {
        _opening = true;
        _error = '';
      });

      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => RuleBrowsePage(
            site: plan,
            navigationSite: widget.site,
            listTitle: '検索：$keyword',
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(title: Text('${widget.site.name}を検索')),
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _query,
            autofocus: true,
            enabled: !_opening,
            maxLength: 256,
            autocorrect: false,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: const InputDecoration(
              labelText: '作品名・キーワード',
              hintText: '例：魔法 学園',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.search),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _opening ? null : _search,
            icon: const Icon(Icons.search),
            label: const Text('検索'),
          ),
          const SizedBox(height: 12),
          const Text(
            '複数の単語はスペースで区切って入力できます。'
            'AND検索・OR検索・フレーズ検索の解釈はサイト側の仕様に従います。',
            style: TextStyle(color: Colors.white60),
          ),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 16),
            SelectableText(
              _error,
              style: const TextStyle(color: Colors.orangeAccent),
            ),
          ],
        ],
      ),
    ),
  );
}
