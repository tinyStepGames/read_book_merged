import 'package:flutter/material.dart';

import 'rule_browse_page.dart';
import 'services/site_browse_tab_plan.dart';
import 'services/site_rule_store.dart';

typedef SiteTabPageBuilder =
    Widget Function(
      BuildContext context,
      SavedSiteRule effectiveSite,
      PreferredSizeWidget header,
    );

class SiteBrowseTabsView extends StatefulWidget {
  const SiteBrowseTabsView({super.key, required this.site, this.pageBuilder});

  final SavedSiteRule site;

  /// 通信なしの表示テストにも使う。
  final SiteTabPageBuilder? pageBuilder;

  @override
  State<SiteBrowseTabsView> createState() => _SiteBrowseTabsViewState();
}

class _SiteBrowseTabsViewState extends State<SiteBrowseTabsView>
    with SingleTickerProviderStateMixin {
  late TabController _controller;
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _createController();
  }

  void _createController() {
    _controller = TabController(
      length: widget.site.browseTabs.length + 1,
      initialIndex: _selected,
      vsync: this,
    );
    _controller.addListener(_onTabChanged);
  }

  void _onTabChanged() {
    if (_controller.index == _selected || !mounted) return;

    setState(() => _selected = _controller.index);
  }

  @override
  void didUpdateWidget(covariant SiteBrowseTabsView oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.site.id != widget.site.id ||
        oldWidget.site.updatedAt != widget.site.updatedAt ||
        oldWidget.site.browseTabs.length != widget.site.browseTabs.length) {
      _controller.removeListener(_onTabChanged);
      _controller.dispose();
      _selected = 0;
      _createController();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTabChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final PreferredSizeWidget header = TabBar(
      controller: _controller,
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      tabs: [
        const Tab(text: '作品一覧'),
        for (final tab in widget.site.browseTabs) Tab(text: tab.title),
      ],
    );

    final effective = _selected == 0
        ? widget.site
        : makeSiteBrowseTabPlan(
            widget.site,
            widget.site.browseTabs[_selected - 1],
          );

    final tabId = _selected == 0
        ? 'main'
        : widget.site.browseTabs[_selected - 1].id;

    // 選択中のタブだけ構築する。
    // 切り替え時に前の一覧を破棄し、進行中の通信も一覧側で中止する。
    return KeyedSubtree(
      key: ValueKey('${widget.site.id}:browse-tab:$tabId'),
      child:
          widget.pageBuilder?.call(context, effective, header) ??
          RuleBrowsePage(
            site: effective,
            navigationSite: widget.site,
            listTitle: widget.site.name,
            tabsHeader: header,
          ),
    );
  }
}
