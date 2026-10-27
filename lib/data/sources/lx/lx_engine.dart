import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'lx_runtime.dart';

/// 一个已加载的 LX 源（全部由用户导入）。
class LxSourceEntry {
  LxSourceEntry(this.id, this.name, this.enabled, this.code);

  final String id;
  final String name;
  bool enabled;
  final String code;

  LxRuntime? runtime;

  /// 源自报的平台 -> 平台定义。
  Map<String, dynamic> get defs {
    final sources = runtime?.definition?['sources'];
    return sources is Map ? Map<String, dynamic>.from(sources) : const {};
  }
}

/// 管理所有 LX 源：加载用户导入的源、登记平台、并按平台分发 musicUrl / lyric / pic。
///
/// 多个源若支持同一平台，优先用用户选中的主音源，其余按导入顺序依次尝试，
/// 实现“跨源兜底”。
/// 源不内置，全部由用户在设置里导入 .js 文件后生效。
class LxSourceManager extends ChangeNotifier {
  LxSourceManager(this.platform);

  /// 设备平台串（windows / android / ios / macos / linux）。
  final String platform;

  final List<LxSourceEntry> entries = [];
  final Map<String, List<String>> _platformSources = {};

  /// 用户选定的主 LX 源 id。为 null 时按导入顺序分发。
  String? _primaryId;
  String? get primaryId => _primaryId;

  LxSourceEntry? _byId(String id) => entries.where((e) => e.id == id).firstOrNull;

  /// 按 id 查找已导入的源（供界面与主音源路由使用）。
  LxSourceEntry? entryById(String id) => _byId(id);

  /// 该源是否声明了平台的某个能力（musicUrl / lyric / pic / musicSearch）。
  bool entrySupports(String id, String platform, String action) {
    final e = _byId(id);
    if (!_usable(e)) return false;
    final actions = e!.defs[platform]?['actions'];
    return actions is List && actions.contains(action);
  }

  /// 该源声明的平台标识列表（用于界面展示）。
  List<String> platformsOf(String id) => _byId(id)?.defs.keys.toList() ?? const [];

  /// 已登记平台 -> 平台中文名（来自各源自报的 inited 事件）。
  Map<String, String> get platformNames {
    final out = <String, String>{};
    for (final e in entries) {
      e.defs.forEach((p, d) => out.putIfAbsent(p, () => '${d['name'] ?? p}'));
    }
    return out;
  }

  /// 加载已保存的用户源并启动运行时。
  Future<void> init() async {
    await _loadSaved();
    await _startAll();
    notifyListeners();
  }

  Future<Directory> _dir() async {
    final dir = await getApplicationSupportDirectory();
    final base = Directory('${dir.path}/lx_sources');
    if (!await base.exists()) await base.create(recursive: true);
    return base;
  }

  Future<void> _loadSaved() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('lx.userSources') ?? [];
    final savedPrimary = prefs.getString('lx.primary');
    if (raw.isEmpty) return;
    final base = await _dir();
    for (final item in raw) {
      try {
        final m = Map<String, dynamic>.from(jsonDecode(item) as Map);
        final id = m['id'] as String;
        final code = await File('${base.path}/$id.js').readAsString();
        entries.add(LxSourceEntry(id, (m['name'] as String?) ?? id, (m['enabled'] as bool?) ?? true, code));
      } catch (_) {}
    }
    if (savedPrimary != null && _byId(savedPrimary)?.enabled == true) _primaryId = savedPrimary;
  }

  Future<void> _startAll() async {
    for (final e in entries) {
      if (e.runtime != null) continue;
      final rt = LxRuntime(e.id, e.name, platform, code: e.code);
      e.runtime = rt;
      try {
        await rt.load();
      } catch (err) {
        debugPrint('lx load ${e.id} failed: $err');
        e.enabled = false;
      }
      for (final p in e.defs.keys) {
        _platformSources.putIfAbsent(p, () => []).add(e.id);
      }
    }
  }

  /// 导入一个 LX 源文件（[path]），保存到应用目录并立即启用。
  Future<LxSourceEntry> importSource(String path, {String? name}) async {
    final code = await File(path).readAsString();
    final id = _uniqueId(path);
    final label = name ?? id;
    final base = await _dir();
    await File('${base.path}/$id.js').writeAsString(code);

    final entry = LxSourceEntry(id, label, true, code);
    final rt = LxRuntime(id, label, platform, code: code);
    entry.runtime = rt;
    try {
      await rt.load();
    } catch (err) {
      debugPrint('lx import $id failed: $err');
    }
    for (final p in entry.defs.keys) {
      _platformSources.putIfAbsent(p, () => []).add(id);
    }
    entries.add(entry);
    await _persist();
    notifyListeners();
    return entry;
  }

  Future<void> removeSource(String id) async {
    final entry = _byId(id);
    if (entry == null) return;
    entry.runtime?.dispose();
    entries.removeWhere((e) => e.id == id);
    _platformSources.forEach((p, ids) => ids.remove(id));
    if (_primaryId == id) {
      _primaryId = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('lx.primary');
    }
    final base = await _dir();
    final f = File('${base.path}/$id.js');
    if (await f.exists()) await f.delete();
    await _persist();
    notifyListeners();
  }

  void setEnabled(String id, bool enabled) {
    final entry = _byId(id);
    if (entry == null) return;
    entry.enabled = enabled;
    if (!enabled && _primaryId == id) {
      _primaryId = null;
      SharedPreferences.getInstance().then((p) => p.remove('lx.primary'));
    }
    _persist();
    notifyListeners();
  }

  /// 选择主 LX 源；[id] 为 null 表示取消（由官方源解析）。
  Future<void> setPrimary(String? id) async {
    final next = id != null && _byId(id)?.enabled == true ? id : null;
    if (next == _primaryId) return;
    _primaryId = next;
    final prefs = await SharedPreferences.getInstance();
    if (next == null) {
      await prefs.remove('lx.primary');
    } else {
      await prefs.setString('lx.primary', next);
    }
    notifyListeners();
  }

  Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    final list = entries.map((e) => jsonEncode({'id': e.id, 'name': e.name, 'enabled': e.enabled})).toList();
    await prefs.setStringList('lx.userSources', list);
  }

  String _uniqueId(String path) {
    final file = path.split(RegExp(r'[\\/]')).last;
    final base = RegExp(r'[A-Za-z0-9_]+').stringMatch(file) ?? 'source';
    var id = base, i = 1;
    while (_byId(id) != null) {
      id = '$base${i++}';
    }
    return id;
  }

  /// 该平台的源顺序：主音源优先，其余按导入顺序兜底。
  List<String> _sourcesFor(String platform) {
    final ids = List<String>.from(_platformSources[platform] ?? const <String>[]);
    final primary = _primaryId;
    if (primary != null) {
      final i = ids.indexOf(primary);
      if (i > 0) {
        ids.removeAt(i);
        ids.insert(0, primary);
      }
    }
    return ids;
  }

  /// 原始 musicInfo 缓存。
  ///
  /// LX 的 musicUrl 需要平台专有字段（酷狗 hash / types、QQ songmid 等），
  /// 而 [Song] 模型存不下，故按 'platform:id' 暂存完整对象，解析时优先使用。
  final Map<String, Map<String, dynamic>> _infoCache = {};

  static String _infoKey(String platform, String id) => '$platform:$id';

  void cacheInfo(String platform, Map<String, dynamic> item) {
    final id = '${item['id'] ?? item['songmid'] ?? item['hash'] ?? ''}';
    if (id.isEmpty) return;
    _infoCache[_infoKey(platform, id)] = Map<String, dynamic>.from(item);
  }

  Map<String, dynamic>? infoFor(String platform, String id) => _infoCache[_infoKey(platform, id)];

  /// 该平台是否有源支持指定 action（musicUrl / lyric / pic / musicSearch）。
  bool supportsAction(String platform, String action) {
    for (final sid in _sourcesFor(platform)) {
      final e = _byId(sid);
      if (!_usable(e)) continue;
      final actions = e!.defs[platform]?['actions'];
      if (actions is List && actions.contains(action)) return true;
    }
    return false;
  }

  /// 支持搜索的平台（平台标识 -> 名称）。
  Map<String, String> get searchablePlatforms => {
        for (final e in platformNames.entries)
          if (supportsAction(e.key, 'musicSearch')) e.key: e.value
      };

  /// 跨平台搜索：分发 musicSearch，返回原始 musicInfo 列表。
  ///
  /// 只有自报了 musicSearch 能力的源才会被调用（星海这类纯解析源不支持）。
  Future<List<Map<String, dynamic>>> search(String platform, String keyword, {int limit = 30, int page = 1}) async {
    for (final sid in _sourcesFor(platform)) {
      final e = _byId(sid);
      if (!_usable(e)) continue;
      try {
        final r = await e!.runtime!.dispatch('musicSearch', platform, {'keyword': keyword, 'limit': limit, 'page': page});
        final list = r is Map ? (r['list'] as List?) : (r as List?);
        if (list == null) continue;
        return [for (final x in list) Map<String, dynamic>.from(x as Map)];
      } catch (err) {
        debugPrint('lx $sid search($platform) failed: $err');
      }
    }
    return const [];
  }

  Future<List<Map<String, dynamic>>> searchEntry(String sourceId, String platform, String keyword, {int limit = 30, int page = 1}) async {
    final entry = _byId(sourceId);
    if (!_usable(entry) || !entrySupports(sourceId, platform, 'musicSearch')) return const [];
    try {
      final result = await entry!.runtime!.dispatch('musicSearch', platform, {'keyword': keyword, 'limit': limit, 'page': page});
      final list = result is Map ? (result['list'] as List?) : (result as List?);
      if (list == null) return const [];
      return [for (final item in list) Map<String, dynamic>.from(item as Map)];
    } catch (err) {
      debugPrint('lx $sourceId search($platform) failed: $err');
      return const [];
    }
  }

  /// 解析播放地址，返回 null 表示所有源都失败。
  Future<String?> resolveUrl(String platform, Map<String, dynamic> musicInfo, String quality) async {
    for (final sid in _sourcesFor(platform)) {
      final e = _byId(sid);
      if (!_usable(e)) continue;
      try {
        final r = await e!.runtime!.dispatch('musicUrl', platform, {'musicInfo': musicInfo, 'type': quality});
        if (r is String) {
          final trimmed = r.trim();
          if (trimmed.isNotEmpty && RegExp(r'^https?://').hasMatch(trimmed)) return trimmed;
        }
      } catch (err) {
        debugPrint('lx $sid musicUrl($platform) failed: $err');
      }
    }
    return null;
  }

  /// 解析歌词 { lyric, tlyric }，失败返回 null。
  Future<Map<String, dynamic>?> resolveLyric(String platform, Map<String, dynamic> musicInfo) async {
    for (final sid in _sourcesFor(platform)) {
      final e = _byId(sid);
      if (!_usable(e)) continue;
      try {
        final r = await e!.runtime!.dispatch('lyric', platform, {'musicInfo': musicInfo, 'type': ''});
        if (r is Map) return Map<String, dynamic>.from(r);
      } catch (err) {
        debugPrint('lx $sid lyric($platform) failed: $err');
      }
    }
    return null;
  }

  /// 解析封面地址，失败返回 null。
  Future<String?> resolvePic(String platform, Map<String, dynamic> musicInfo) async {
    for (final sid in _sourcesFor(platform)) {
      final e = _byId(sid);
      if (!_usable(e)) continue;
      try {
        final r = await e!.runtime!.dispatch('pic', platform, {'musicInfo': musicInfo, 'type': ''});
        if (r is String) return r.trim();
      } catch (err) {
        debugPrint('lx $sid pic($platform) failed: $err');
      }
    }
    return null;
  }

  bool _usable(LxSourceEntry? e) => e != null && e.enabled && e.runtime != null && e.runtime!.loaded;
}
