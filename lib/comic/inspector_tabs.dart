import 'package:flutter/material.dart';

/// ページを常時表示し、隣接するパネルだけを切り替える。
///
/// 同じFlex配下の同じ位置にWebViewを置き続け、
/// タブ操作や縦横レイアウト変更で作り直さない。
class InspectorTabs extends StatefulWidget {
  const InspectorTabs({
    super.key,
    required this.browser,
    required this.tree,
    required this.details,
  });

  final Widget browser;
  final Widget tree;
  final Widget details;

  @override
  State<InspectorTabs> createState() => _InspectorTabsState();
}

class _InspectorTabsState extends State<InspectorTabs>
    with SingleTickerProviderStateMixin {
  late final TabController _controller;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _controller = TabController(length: 2, vsync: this);
    _controller.addListener(_changed);
  }

  void _changed() {
    if (_index != _controller.index) {
      setState(() => _index = _controller.index);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    super.dispose();
  }

  Widget _panel() => Column(
    children: [
      Material(
        color: Theme.of(context).colorScheme.surface,
        child: TabBar(
          controller: _controller,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: const [
            Tab(
              key: ValueKey('inspector-tab-tree'),
              text: '要素ツリー',
              icon: Icon(Icons.account_tree_outlined),
            ),
            Tab(
              key: ValueKey('inspector-tab-details'),
              text: '選択情報',
              icon: Icon(Icons.tune),
            ),
          ],
        ),
      ),
      Expanded(
        child: IndexedStack(
          index: _index,
          children: [
            KeyedSubtree(
              key: const ValueKey('inspector-tree-pane'),
              child: widget.tree,
            ),
            KeyedSubtree(
              key: const ValueKey('inspector-details-pane'),
              child: widget.details,
            ),
          ],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide = constraints.maxWidth >= 900;

      return Flex(
        key: const ValueKey('inspector-split'),
        direction: wide ? Axis.horizontal : Axis.vertical,
        children: [
          Expanded(
            flex: wide ? 3 : 1,
            child: KeyedSubtree(
              key: const ValueKey('inspector-page-pane'),
              child: widget.browser,
            ),
          ),
          SizedBox(
            width: wide ? 1 : null,
            height: wide ? null : 1,
            child: ColoredBox(color: Theme.of(context).dividerColor),
          ),
          Expanded(
            flex: wide ? 2 : 1,
            child: KeyedSubtree(
              key: const ValueKey('inspector-tools-pane'),
              child: _panel(),
            ),
          ),
        ],
      );
    },
  );
}
