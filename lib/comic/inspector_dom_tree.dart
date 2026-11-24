import 'dart:math' as math;

import 'package:flutter/material.dart';

class InspectorTreeRow {
  const InspectorTreeRow({
    required this.id,
    required this.depth,
    required this.tag,
    required this.attrs,
    required this.text,
    required this.childCount,
    required this.expanded,
    required this.selectable,
    required this.more,
    required this.remaining,
    required this.canLoadMore,
  });

  final int id;
  final int depth;
  final String tag;
  final Map<String, String> attrs;
  final String text;
  final int childCount;
  final bool expanded;
  final bool selectable;
  final bool more;
  final int remaining;
  final bool canLoadMore;

  factory InspectorTreeRow.fromJson(Object? value) {
    if (value is! Map) {
      throw const FormatException('要素行の形式が不正です。');
    }

    final id = value['id'];
    final depth = value['depth'];
    final tag = value['tag'];
    final text = value['text'];
    final attrs = value['attrs'];
    final count = value['childCount'];
    final remaining = value['remaining'];

    if (id is! int ||
        id < 1 ||
        id > 20000 ||
        depth is! int ||
        depth < 0 ||
        depth > 81 ||
        tag is! String ||
        tag.length > 120 ||
        text is! String ||
        text.length > 200 ||
        attrs is! Map ||
        attrs.length > 8 ||
        count is! int ||
        count < 0 ||
        remaining is! int ||
        remaining < 0 ||
        value['expanded'] is! bool ||
        value['selectable'] is! bool ||
        value['more'] is! bool ||
        value['canLoadMore'] is! bool) {
      throw const FormatException('要素行の値が不正です。');
    }

    final attributes = <String, String>{};

    for (final entry in attrs.entries) {
      if (entry.key is! String ||
          entry.value is! String ||
          (entry.key as String).length > 80 ||
          (entry.value as String).length > 160) {
        throw const FormatException('属性の値が不正です。');
      }
      attributes[entry.key as String] = entry.value as String;
    }

    return InspectorTreeRow(
      id: id,
      depth: depth,
      tag: tag,
      attrs: Map.unmodifiable(attributes),
      text: text,
      childCount: count,
      expanded: value['expanded'] as bool,
      selectable: value['selectable'] as bool,
      more: value['more'] as bool,
      remaining: remaining,
      canLoadMore: value['canLoadMore'] as bool,
    );
  }
}

class InspectorTreeSnapshot {
  const InspectorTreeSnapshot({
    required this.rows,
    required this.selectedId,
    required this.expanded,
    required this.limited,
  });

  final List<InspectorTreeRow> rows;
  final int selectedId;
  final Set<int> expanded;
  final bool limited;

  factory InspectorTreeSnapshot.fromJson(Object? value) {
    if (value is! Map ||
        value['rows'] is! List ||
        value['expanded'] is! List ||
        value['selectedId'] is! int ||
        value['limited'] is! bool) {
      throw const FormatException('要素ツリーの形式が不正です。');
    }

    final rows = value['rows'] as List;
    final expanded = value['expanded'] as List;
    final selectedId = value['selectedId'] as int;

    if (rows.length > 1200 ||
        expanded.length > 2000 ||
        selectedId < 0 ||
        selectedId > 20000 ||
        expanded.any((id) => id is! int || id < 1 || id > 20000)) {
      throw const FormatException('要素ツリーが上限を超えています。');
    }

    final parsedRows = rows.map(InspectorTreeRow.fromJson).toList();
    final nodeIds = <int>{};

    for (final row in parsedRows) {
      if (!row.more && !nodeIds.add(row.id)) {
        throw const FormatException('要素IDが重複しています。');
      }
    }

    return InspectorTreeSnapshot(
      rows: List.unmodifiable(parsedRows),
      selectedId: selectedId,
      expanded: Set.unmodifiable(expanded.cast<int>()),
      limited: value['limited'] as bool,
    );
  }
}

typedef InspectorTreeReader =
    Future<InspectorTreeSnapshot> Function(
      Set<int> expanded,
      Map<int, int> limits,
      bool reveal,
    );

class InspectorDomTree extends StatefulWidget {
  const InspectorDomTree({
    super.key,
    required this.revision,
    required this.onRead,
    required this.onSelect,
  });

  final int revision;
  final InspectorTreeReader onRead;
  final Future<bool> Function(int id) onSelect;

  @override
  State<InspectorDomTree> createState() => _InspectorDomTreeState();
}

class _InspectorDomTreeState extends State<InspectorDomTree> {
  final _scroll = ScrollController();
  Set<int> _expanded = {};
  final Map<int, int> _limits = {};
  InspectorTreeSnapshot? _snapshot;
  String _error = '';
  bool _busy = false;
  int _request = 0;
  double _rowHeight = 44;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh(reveal: true);
    });
  }

  @override
  void didUpdateWidget(covariant InspectorDomTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh(reveal: true);
      });
    }
  }

  Future<void> _refresh({bool reveal = false}) async {
    final request = ++_request;
    setState(() {
      _busy = true;
      _error = '';
    });

    try {
      final snapshot = await widget.onRead(
        Set.of(_expanded),
        Map.of(_limits),
        reveal,
      );

      if (!mounted || request != _request) return;

      setState(() {
        _snapshot = snapshot;
        _expanded = Set.of(snapshot.expanded);
      });

      if (reveal) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || request != _request || !_scroll.hasClients) {
            return;
          }

          final index = snapshot.rows.indexWhere(
            (row) => !row.more && row.id == snapshot.selectedId,
          );
          if (index < 0) return;

          final target = (index * _rowHeight)
              .clamp(
                _scroll.position.minScrollExtent,
                _scroll.position.maxScrollExtent,
              )
              .toDouble();

          _scroll.jumpTo(target);
        });
      }
    } catch (error) {
      if (mounted && request == _request) {
        setState(() => _error = '$error');
      }
    } finally {
      if (mounted && request == _request) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _select(InspectorTreeRow row) async {
    if (_busy || !row.selectable) return;

    setState(() {
      _busy = true;
      _error = '';
    });

    try {
      final selected = await widget.onSelect(row.id);
      if (!mounted) return;

      if (!selected) {
        setState(() {
          _error =
              'この要素は選択できません。'
              'ページの更新や、まとまりの範囲外でないか確認してください。';
        });
        return;
      }

      await _refresh(reveal: true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _request++;
    _scroll.dispose();
    super.dispose();
  }

  Widget _row(InspectorTreeRow row) {
    final selected = !row.more && _snapshot?.selectedId == row.id;

    if (row.more) {
      return Padding(
        padding: EdgeInsets.only(left: math.min(row.depth, 30) * 16.0 + 40),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            key: ValueKey('dom-more-${row.id}'),
            onPressed: _busy || !row.canLoadMore
                ? null
                : () {
                    _limits[row.id] = math.min(
                      600,
                      (_limits[row.id] ?? 60) + 60,
                    );
                    _refresh();
                  },
            child: Text(
              row.canLoadMore
                  ? '続きを表示（残り${row.remaining}要素）'
                  : '子要素は先頭600件まで表示しています',
            ),
          ),
        ),
      );
    }

    return Material(
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer
          : Colors.transparent,
      child: InkWell(
        key: ValueKey('dom-node-${row.id}'),
        onTap: _busy || !row.selectable ? null : () => _select(row),
        child: Row(
          children: [
            SizedBox(width: math.min(row.depth, 30) * 16.0),
            SizedBox(
              width: 40,
              child: row.childCount == 0
                  ? null
                  : IconButton(
                      key: ValueKey('dom-expand-${row.id}'),
                      tooltip: row.expanded ? '子要素を閉じる' : '子要素を開く',
                      padding: EdgeInsets.zero,
                      onPressed: _busy
                          ? null
                          : () {
                              if (!_expanded.add(row.id)) {
                                _expanded.remove(row.id);
                              }
                              _refresh();
                            },
                      icon: Icon(
                        row.expanded ? Icons.expand_more : Icons.chevron_right,
                      ),
                    ),
            ),
            if (!row.selectable)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: Tooltip(
                  message: 'まとまりの範囲外です。階層の開閉だけできます。',
                  child: Icon(Icons.lock_outline, size: 15),
                ),
              ),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '<${row.tag}',
                      style: const TextStyle(color: Colors.lightBlueAccent),
                    ),
                    for (final entry in row.attrs.entries) ...[
                      TextSpan(
                        text: ' ${entry.key}',
                        style: const TextStyle(color: Colors.orangeAccent),
                      ),
                      TextSpan(
                        text: '="${entry.value}"',
                        style: const TextStyle(color: Colors.lightGreenAccent),
                      ),
                    ],
                    const TextSpan(
                      text: '>',
                      style: TextStyle(color: Colors.lightBlueAccent),
                    ),
                    if (row.text.isNotEmpty) TextSpan(text: ' ${row.text}'),
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 13,
                  color: Colors.white,
                ),
              ),
            ),
            if (selected)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.check, size: 18),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    _rowHeight = math.max(
      44.0,
      MediaQuery.textScalerOf(context).scale(16) + 20,
    );

    return ColoredBox(
      color: const Color(0xff17191d),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  key: const ValueKey('dom-refresh'),
                  onPressed: _busy ? null : () => _refresh(),
                  icon: const Icon(Icons.refresh),
                  label: const Text('ツリーを更新'),
                ),
                OutlinedButton(
                  key: const ValueKey('dom-reveal'),
                  onPressed: _busy ? null : () => _refresh(reveal: true),
                  child: const Text('選択要素へ'),
                ),
                const Text(
                  '▶で開閉／行を押して選択／横スクロールできます',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                _error,
                style: const TextStyle(color: Colors.orangeAccent),
              ),
            ),
          if (snapshot?.limited == true)
            const Padding(
              padding: EdgeInsets.all(8),
              child: Text(
                '表示上限に達しました。不要な枝を閉じて更新してください。',
                style: TextStyle(color: Colors.orangeAccent),
              ),
            ),
          Expanded(
            child: snapshot == null
                ? Center(
                    child: Text(
                      _busy ? '要素ツリーを取得中…' : '更新して要素を確認してください。',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  )
                : LayoutBuilder(
                    builder: (context, constraints) => SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: math.max(constraints.maxWidth, 1000),
                        height: constraints.maxHeight,
                        child: ListView.builder(
                          key: const PageStorageKey('inspector-dom-tree-list'),
                          controller: _scroll,
                          itemExtent: _rowHeight,
                          itemCount: snapshot.rows.length,
                          itemBuilder: (context, index) =>
                              _row(snapshot.rows[index]),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
