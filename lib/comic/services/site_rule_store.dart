import 'site_browse_tab.dart';
import 'site_search_settings.dart';
import 'tag_navigation_settings.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'list_extraction_rule.dart';
import 'chapter_image_settings.dart';
import 'site_reading_settings.dart';

class SavedSiteRule {
  const SavedSiteRule({
    required this.id,
    required this.name,
    required this.rules,
    required this.updatedAt,
    this.images,
    this.tagNavigation,
    this.searchSettings,
    this.browseTabs = const [],
    this.readingSettings,
  });

  final String id;
  final String name;
  final Map<String, ListExtractionRule> rules;
  final DateTime updatedAt;
  final ChapterImageSettings? images;
  final TagNavigationSettings? tagNavigation;
  final SiteSearchSettings? searchSettings;
  final List<SiteBrowseTab> browseTabs;
  final SiteReadingSettings? readingSettings;

  SiteReadingMode get readingMode =>
      readingSettings?.mode ?? SiteReadingMode.chapters;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'rules': rules.map((key, rule) => MapEntry(key, rule.toJson())),
    if (readingSettings != null) 'readingSettings': readingSettings!.toJson(),
    if (images != null) 'images': images!.toJson(),
    if (tagNavigation != null) 'tagNavigation': tagNavigation!.toJson(),
    if (searchSettings != null) 'searchSettings': searchSettings!.toJson(),
    if (browseTabs.isNotEmpty)
      'browseTabs': browseTabs.map((tab) => tab.toJson()).toList(),
  };

  factory SavedSiteRule.fromJson(Map<String, dynamic> data) {
    if (data.keys.any(
      (key) => !const {
        'id',
        'name',
        'updatedAt',
        'rules',
        'images',
        'tagNavigation',
        'searchSettings',
        'browseTabs',
        'readingSettings',
      }.contains(key),
    )) {
      throw const FormatException('未対応のサイト保存項目です');
    }

    final id = data['id'] as String;
    final name = checkedSiteRuleName(data['name'] as String);
    final updatedAt = DateTime.parse(data['updatedAt'] as String);
    final raw = Map<String, dynamic>.from(data['rules'] as Map);

    if (!RegExp(r'^[A-Za-z0-9_-]{22}$').hasMatch(id) ||
        raw.isEmpty ||
        raw.keys.any((key) => !const ['works', 'chapters'].contains(key))) {
      throw const FormatException('サイト保存情報が不正です');
    }

    final rules = <String, ListExtractionRule>{};
    for (final entry in raw.entries) {
      final rule = ListExtractionRule.parse(jsonEncode(entry.value));
      if (rule.kind != entry.key) {
        throw const FormatException('一覧の保存先と種類が一致しません');
      }
      rules[entry.key] = rule;
    }

    final images = data['images'] == null
        ? null
        : ChapterImageSettings.parse(jsonEncode(data['images']));
    images?.validateOrigins(rules.values.map((rule) => rule.pageUrl));

    final tagNavigation = data['tagNavigation'] == null
        ? null
        : TagNavigationSettings.fromJson(
            Map<String, dynamic>.from(data['tagNavigation'] as Map),
          );
    tagNavigation?.validateFor(rules.values);

    final searchSettings = data['searchSettings'] == null
        ? null
        : SiteSearchSettings.fromJson(
            Map<String, dynamic>.from(data['searchSettings'] as Map),
          );
    searchSettings?.validateFor(rules);

    final browseTabs = SiteBrowseTab.parseList(data['browseTabs']);
    SiteBrowseTab.validateList(browseTabs, rules);

    final readingSettings = data['readingSettings'] == null
        ? null
        : SiteReadingSettings.fromJson(
            Map<String, dynamic>.from(data['readingSettings'] as Map),
          );
    readingSettings?.validateFor(rules.values);

    return SavedSiteRule(
      id: id,
      name: name,
      rules: Map.unmodifiable(rules),
      updatedAt: updatedAt.toUtc(),
      images: images,
      tagNavigation: tagNavigation,
      searchSettings: searchSettings,
      browseTabs: browseTabs,
      readingSettings: readingSettings,
    );
  }
}

String checkedSiteRuleName(String value) {
  final name = value.trim();
  if (name.isEmpty || name.length > 100) {
    throw const FormatException('サイト保存名は1～100文字で入力してください');
  }
  return name;
}

/// 漫画保存フォルダーの隣に、名前付きの設定だけを保存する。
/// HTML、画像、Cookieは保存しない。
class SiteRuleStore {
  SiteRuleStore(Directory comicsRoot)
    : _file = File(p.join(comicsRoot.parent.path, '_site_rules', 'sites.json'));

  final File _file;
  static final Map<String, Future<void>> _queues = {};
  static const _maxBytes = 4 * 1024 * 1024;
  static const _maxSites = 200;

  Future<T> _locked<T>(Future<T> Function() action) {
    final key = p.normalize(_file.absolute.path);
    final previous = _queues[key] ?? Future<void>.value();
    final task = previous.then((_) => action());

    // 次の操作が、直前の失敗によって実行されなくなるのを防ぐ。
    _queues[key] = task.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );

    return task;
  }

  Future<List<SavedSiteRule>> _read() async {
    if (!await _file.exists()) return [];
    if (await _file.length() > _maxBytes) {
      throw const FormatException('サイトルール保存ファイルが大きすぎます');
    }

    // 破損を空データ扱いにしない。上書きせずエラーを返す。
    final data = Map<String, dynamic>.from(
      jsonDecode(await _file.readAsString()) as Map,
    );

    if (data['version'] != 1 ||
        data.keys.any((key) => !const {'version', 'sites'}.contains(key)) ||
        data['sites'] is! List) {
      throw const FormatException('サイトルール保存形式が不正です');
    }

    final raw = data['sites'] as List;
    if (raw.length > _maxSites) {
      throw const FormatException('保存サイト数が上限を超えています');
    }

    final result = raw
        .map(
          (value) =>
              SavedSiteRule.fromJson(Map<String, dynamic>.from(value as Map)),
        )
        .toList();

    if (result.map((site) => site.id).toSet().length != result.length) {
      throw const FormatException('保存サイトIDが重複しています');
    }

    result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return result;
  }

  Future<void> _write(List<SavedSiteRule> sites) async {
    if (sites.length > _maxSites) {
      throw const FormatException('保存できるサイトは200件までです');
    }

    for (final site in sites) {
      site.readingSettings?.validateFor(site.rules.values);
      SiteBrowseTab.validateList(site.browseTabs, site.rules);
      site.searchSettings?.validateFor(site.rules);
      site.images?.validateOrigins(
        site.rules.values.map((rule) => rule.pageUrl),
      );
    }

    final text = jsonEncode({
      'version': 1,
      'sites': sites.map((site) => site.toJson()).toList(),
    });

    if (utf8.encode(text).length > _maxBytes) {
      throw const FormatException('サイトルールの保存容量上限を超えています');
    }

    await _file.parent.create(recursive: true);
    // 初回の書き換え前に、既存の設定を一度だけ退避する。
    if (await _file.exists()) {
      final backup = File('${_file.path}.before-body-rules-v1.bak');
      if (!await backup.exists()) {
        await _file.copy(backup.path);
      }
    }

    final temporary = File('${_file.path}.part');
    await temporary.writeAsString(text, flush: true);
    await temporary.rename(_file.path);
  }

  String _newId(List<SavedSiteRule> sites) {
    final random = Random.secure();
    String id;
    do {
      id = base64Url
          .encode(List<int>.generate(16, (_) => random.nextInt(256)))
          .replaceAll('=', '');
    } while (sites.any((site) => site.id == id));
    return id;
  }

  int _requiredIndex(List<SavedSiteRule> sites, String id) {
    final index = sites.indexWhere((site) => site.id == id);
    if (index < 0) {
      throw StateError('保存先が見つかりません。管理画面を開き直してください');
    }
    return index;
  }

  Future<List<SavedSiteRule>> load() => _locked(_read);

  Future<SavedSiteRule> save({
    String? id,
    required String name,
    required ListExtractionRule rule,
  }) => _locked(() async {
    final checkedName = checkedSiteRuleName(name);
    final checkedRule = ListExtractionRule.parse(rule.encodeJson());
    final sites = await _read();
    final index = id == null ? -1 : _requiredIndex(sites, id);
    final rules = <String, ListExtractionRule>{};

    if (index >= 0) rules.addAll(sites[index].rules);
    rules[checkedRule.kind] = checkedRule;

    final saved = SavedSiteRule(
      id: id ?? _newId(sites),
      images: index >= 0 ? sites[index].images : null,
      tagNavigation: index >= 0 ? sites[index].tagNavigation : null,
      searchSettings: index >= 0 ? sites[index].searchSettings : null,
      browseTabs: index >= 0 ? sites[index].browseTabs : const [],
      readingSettings: index >= 0 ? sites[index].readingSettings : null,
      name: checkedName,
      rules: Map.unmodifiable(rules),
      updatedAt: DateTime.now().toUtc(),
    );

    if (index < 0) {
      sites.add(saved);
    } else {
      sites[index] = saved;
    }

    await _write(sites);
    return saved;
  });

  Future<SavedSiteRule> saveImages({
    required String id,
    required ChapterImageSettings settings,
  }) => _locked(() async {
    final checked = ChapterImageSettings.parse(settings.encodeJson());
    final sites = await _read();
    final index = _requiredIndex(sites, id);
    final old = sites[index];

    checked.validateOrigins(old.rules.values.map((rule) => rule.pageUrl));

    final updated = SavedSiteRule(
      id: old.id,
      name: old.name,
      rules: old.rules,
      images: checked,
      tagNavigation: old.tagNavigation,
      searchSettings: old.searchSettings,
      browseTabs: old.browseTabs,
      readingSettings: old.readingSettings,
      updatedAt: DateTime.now().toUtc(),
    );

    sites[index] = updated;
    await _write(sites);
    return updated;
  });

  Future<void> rename(String id, String name) => _locked(() async {
    final checkedName = checkedSiteRuleName(name);
    final sites = await _read();
    final index = _requiredIndex(sites, id);
    final old = sites[index];

    sites[index] = SavedSiteRule(
      id: old.id,
      name: checkedName,
      rules: old.rules,
      images: old.images,
      tagNavigation: old.tagNavigation,
      searchSettings: old.searchSettings,
      browseTabs: old.browseTabs,
      readingSettings: old.readingSettings,
      updatedAt: DateTime.now().toUtc(),
    );
    await _write(sites);
  });

  Future<SavedSiteRule> duplicate(String id) => _locked(() async {
    final sites = await _read();
    final old = sites[_requiredIndex(sites, id)];
    final base = old.name.length > 96 ? old.name.substring(0, 96) : old.name;

    final copy = SavedSiteRule.fromJson({
      ...old.toJson(),
      'id': _newId(sites),
      'name': '$base（複製）',
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });

    sites.add(copy);
    await _write(sites);
    return copy;
  });

  /// 1サイト分を検証して一括保存する。
  /// 更新時には取り込み先のIDを維持する。
  Future<SavedSiteRule> importSiteBundle({
    required SavedSiteRule incoming,
    String? targetId,
    DateTime? expectedUpdatedAt,
  }) => _locked(() async {
    final checked = SavedSiteRule.fromJson(incoming.toJson());
    final sites = await _read();
    final index = targetId == null ? -1 : _requiredIndex(sites, targetId);

    if (index >= 0 &&
        (expectedUpdatedAt == null ||
            sites[index].updatedAt != expectedUpdatedAt.toUtc())) {
      throw StateError(
        '確認中に保存先の設定が変更されました。'
        '取り込み画面を開き直してください',
      );
    }

    final saved = SavedSiteRule.fromJson({
      ...checked.toJson(),
      'id': targetId ?? _newId(sites),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });

    if (index < 0) {
      sites.add(saved);
    } else {
      sites[index] = saved;
    }

    await _write(sites);
    return saved;
  });

  /// 通常一覧・チャプター・本文画像を保持してタグ先設定だけを保存する。
  /// settings が null の場合は専用設定を削除する。
  Future<SavedSiteRule> saveTagNavigation({
    required String id,
    required TagNavigationSettings? settings,
    required DateTime expectedUpdatedAt,
  }) => _locked(() async {
    final sites = await _read();
    final index = _requiredIndex(sites, id);
    final old = sites[index];

    if (old.updatedAt != expectedUpdatedAt.toUtc()) {
      throw StateError(
        '編集中にサイト設定が変更されました。'
        '画面を開き直してください',
      );
    }

    final checked = settings == null
        ? null
        : TagNavigationSettings.fromJson(settings.toJson());

    checked?.validateFor(old.rules.values);

    final saved = SavedSiteRule(
      id: old.id,
      name: old.name,
      rules: old.rules,
      images: old.images,
      tagNavigation: checked,
      searchSettings: old.searchSettings,
      browseTabs: old.browseTabs,
      readingSettings: old.readingSettings,
      updatedAt: DateTime.now().toUtc(),
    );

    sites[index] = saved;
    await _write(sites);
    return saved;
  });

  /// 検索設定だけを保存する。nullなら検索設定だけ削除する。
  Future<SavedSiteRule> saveSearchSettings({
    required String id,
    required SiteSearchSettings? settings,
    required DateTime expectedUpdatedAt,
  }) => _locked(() async {
    final sites = await _read();
    final index = _requiredIndex(sites, id);
    final old = sites[index];

    if (old.updatedAt != expectedUpdatedAt.toUtc()) {
      throw StateError('編集中にサイト設定が変更されました。画面を開き直してください');
    }

    final checked = settings == null
        ? null
        : SiteSearchSettings.fromJson(settings.toJson());

    checked?.validateFor(old.rules);

    final data = old.toJson();
    if (checked == null) {
      data.remove('searchSettings');
    } else {
      data['searchSettings'] = checked.toJson();
    }
    data['updatedAt'] = DateTime.now().toUtc().toIso8601String();

    final saved = SavedSiteRule.fromJson(data);
    sites[index] = saved;

    await _write(sites);
    return saved;
  });

  Future<SavedSiteRule> saveBrowseTabs({
    required String id,
    required List<SiteBrowseTab> tabs,
    required DateTime expectedUpdatedAt,
  }) => _locked(() async {
    final sites = await _read();
    final index = _requiredIndex(sites, id);
    final old = sites[index];

    if (old.updatedAt != expectedUpdatedAt.toUtc()) {
      throw StateError('編集中にサイト設定が変更されました。画面を開き直してください');
    }

    final checked = tabs
        .map((tab) => SiteBrowseTab.fromJson(tab.toJson()))
        .toList(growable: false);

    SiteBrowseTab.validateList(checked, old.rules);

    final data = old.toJson();

    if (checked.isEmpty) {
      data.remove('browseTabs');
    } else {
      data['browseTabs'] = checked.map((tab) => tab.toJson()).toList();
    }

    data['updatedAt'] = DateTime.now().toUtc().toIso8601String();

    final saved = SavedSiteRule.fromJson(data);
    sites[index] = saved;

    await _write(sites);
    return saved;
  });

  /// 開き方だけを保存する。既存の一覧・本文画像等は保持する。
  Future<SavedSiteRule> saveReadingSettings({
    required String id,
    required SiteReadingSettings? settings,
    required DateTime expectedUpdatedAt,
  }) => _locked(() async {
    final sites = await _read();
    final index = _requiredIndex(sites, id);
    final old = sites[index];

    if (old.updatedAt != expectedUpdatedAt.toUtc()) {
      throw StateError('編集中にサイト設定が変更されました。画面を開き直してください');
    }

    final checked = settings == null
        ? null
        : SiteReadingSettings.fromJson(settings.toJson());
    checked?.validateFor(old.rules.values);

    final data = old.toJson();

    if (checked == null) {
      data.remove('readingSettings');
    } else {
      data['readingSettings'] = checked.toJson();
    }

    data['updatedAt'] = DateTime.now().toUtc().toIso8601String();

    final saved = SavedSiteRule.fromJson(data);
    sites[index] = saved;

    await _write(sites);
    return saved;
  });

  Future<void> delete(String id) => _locked(() async {
    final sites = await _read();
    final index = _requiredIndex(sites, id);
    sites.removeAt(index);
    await _write(sites);
  });
}
