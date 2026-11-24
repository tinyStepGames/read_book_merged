import 'dart:convert';

import 'site_rule_store.dart';

enum SiteImportChangeKind { added, changed, removed, unchanged, unconfigured }

class SiteImportChange {
  const SiteImportChange({
    required this.key,
    required this.label,
    required this.kind,
  });

  final String key;
  final String label;
  final SiteImportChangeKind kind;

  String get statusLabel => switch (kind) {
    SiteImportChangeKind.added => '新規追加',
    SiteImportChangeKind.changed => '変更あり',
    SiteImportChangeKind.removed => '削除されます',
    SiteImportChangeKind.unchanged => '変更なし',
    SiteImportChangeKind.unconfigured => '未設定のまま',
  };
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }

  if (value is List) {
    return value.map(_canonical).toList(growable: false);
  }

  return value;
}

bool _same(Object? a, Object? b) =>
    jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));

Map<String, Object?> _sections(SavedSiteRule site) {
  final works = site.rules['works'];
  final chapters = site.rules['chapters'];
  final tags = site.tagNavigation;

  return {
    'name': site.name,
    'reading': site.readingSettings?.toJson(),
    'works': works?.toJson(),
    'pagination': works == null || works.paginationUrl.isEmpty
        ? null
        : works.paginationUrl,
    'chapters': chapters?.toJson(),
    'details': chapters == null || chapters.details.isEmpty
        ? null
        : {
            for (final entry in chapters.details.entries)
              entry.key: entry.value.toJson(),
          },
    'images': site.images?.toJson(),
    'tags': tags?.toJson(),
    'tagTransform':
        tags == null || (tags.urlPattern.isEmpty && tags.urlReplacement.isEmpty)
        ? null
        : {'pattern': tags.urlPattern, 'replacement': tags.urlReplacement},
    'search': site.searchSettings?.toJson(),
    'tabs': site.browseTabs.isEmpty
        ? null
        : site.browseTabs.map((tab) => tab.toJson()).toList(),
  };
}

const _labels = <String, String>{
  'name': 'サイト名',
  'reading': '開き方・チャプターなし作品詳細',
  'works': '作品一覧',
  'pagination': '通常一覧のページ送り',
  'chapters': 'チャプター一覧',
  'details': '作品詳細',
  'images': '本文画像',
  'tags': 'タグ先一覧・設定',
  'tagTransform': 'タグURL変換',
  'search': '検索設定（保存値）',
  'tabs': 'サイト別タブ',
};

class SiteImportComparison {
  const SiteImportComparison._({
    required this.isNew,
    required this.incomingName,
    required this.targetName,
    required this.changes,
    required this.removedLabels,
  });

  final bool isNew;
  final String incomingName;
  final String? targetName;
  final List<SiteImportChange> changes;
  final List<String> removedLabels;

  static const referenceNotice =
      '設定単位の比較です。作品一覧・チャプター一覧などは'
      '内部の全設定を含めて比較します。\n'
      '検索・タブが別の一覧ルールを参照している場合、'
      'その保存値が「変更なし」でも参照元の変更が動作に影響する場合があります。';

  bool get hasChanges => changes.any(
    (change) => const {
      SiteImportChangeKind.added,
      SiteImportChangeKind.changed,
      SiteImportChangeKind.removed,
    }.contains(change.kind),
  );

  bool get hasRemovals => removedLabels.isNotEmpty;

  factory SiteImportComparison.compare({
    required SavedSiteRule incoming,
    SavedSiteRule? target,
  }) {
    final before = target == null ? <String, Object?>{} : _sections(target);
    final after = _sections(incoming);
    final changes = <SiteImportChange>[];

    for (final entry in _labels.entries) {
      final oldValue = before[entry.key];
      final newValue = after[entry.key];

      final SiteImportChangeKind kind;
      if (oldValue == null && newValue == null) {
        kind = SiteImportChangeKind.unconfigured;
      } else if (oldValue == null) {
        kind = SiteImportChangeKind.added;
      } else if (newValue == null) {
        kind = SiteImportChangeKind.removed;
      } else if (_same(oldValue, newValue)) {
        kind = SiteImportChangeKind.unchanged;
      } else {
        kind = SiteImportChangeKind.changed;
      }

      changes.add(
        SiteImportChange(key: entry.key, label: entry.value, kind: kind),
      );
    }

    final removals = <String>[
      for (final change in changes)
        if (change.kind == SiteImportChangeKind.removed) change.label,
    ];

    if (target != null &&
        target.browseTabs.isNotEmpty &&
        incoming.browseTabs.isNotEmpty) {
      final incomingIds = incoming.browseTabs.map((tab) => tab.id).toSet();

      for (final tab in target.browseTabs) {
        if (!incomingIds.contains(tab.id)) {
          removals.add('サイト別タブ「${tab.title}」');
        }
      }
    }

    return SiteImportComparison._(
      isNew: target == null,
      incomingName: incoming.name,
      targetName: target?.name,
      changes: List.unmodifiable(changes),
      removedLabels: List.unmodifiable(removals),
    );
  }

  String get actionText => isNew
      ? '「$incomingName」を新しいサイトとして追加します。'
            '同じ名前のサイトがあっても自動では上書きしません。'
      : '「$targetName」の設定一式を取り込み内容で置き換えます。'
            '更新後のサイト名は「$incomingName」です。';

  String toText() {
    final lines = <String>[
      actionText,
      if (hasRemovals) ...[
        '',
        '【削除される設定があります】',
        ...removedLabels.map((label) => '・$label'),
        '取り込み側にない設定は残りません。',
      ],
      '',
      '反映内容の比較',
      ...changes.map((change) => '${change.label}：${change.statusLabel}'),
      '',
      referenceNotice,
      '',
      '保存画像・お気に入り・履歴・閲覧位置・開いたマークは比較・変更の対象外です。',
    ];

    return lines.join('\n');
  }
}
