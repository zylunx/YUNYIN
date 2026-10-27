import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../core/data_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../local_library.dart';
import '../models.dart';
import 'local/local_source.dart';
import 'lx/lx_engine.dart';
import 'lx/lx_source.dart';
import 'music_source.dart';
import 'netease/netease_source.dart';

/// 已注册的播放源。新增平台：实现 [MusicSource] 并加入 [SourceRegistry.create]。
abstract final class SourceRegistry {
  static List<MusicSource> create(LocalLibrary library, LxSourceManager lx) =>
      [NeteaseSource(), LocalSource(library), LxSource(lx)];
}

/// 管理当前播放源，并负责按 [Song.sourceId] 找回对应的源。
///
/// 除内置平台外，用户导入的每个 LX 源也可以被选为“主音源”。选中的源会在
/// 播放时优先解析；同一平台有多个 LX 源时它排在最前，其余按导入顺序兜底。
class SourceManager extends ChangeNotifier {
  SourceManager(this.sources);

  static const _prefsKey = 'source.current';
  static const _primaryKey = 'source.primary';

  final List<MusicSource> sources;
  late MusicSource _current = sources.first;
  late String _primaryId = _fallbackPrimaryId;

  /// 可以切换为当前源的播放源。
  List<MusicSource> get selectable => [for (final s in sources) if (s.selectable) s];

  MusicSource get current => _current;

  /// 用户选定的主音源 id：内置源 id（如 'netease'）或 `lx:<entryId>`。
  String get primaryId => _primaryId;

  bool get primaryIsLx => _primaryId.startsWith('lx:');

  String? get primaryLxId => primaryIsLx ? _primaryId.substring(3) : null;

  /// 当前主音源对应的 LX 源；主音源是官方源时为 null。
  LxSourceEntry? get primaryLx {
    final id = primaryLxId;
    return id == null ? null : lxSource?.manager.entryById(id);
  }

  /// 主音源显示名。
  String get primaryName {
    final entry = primaryLx;
    if (entry != null) return entry.name;
    return sources.where((s) => s.id == _primaryId).firstOrNull?.name ?? _current.name;
  }

  /// “音源”选择列表：内置源 + 已启用的 LX 源（id -> 显示名）。
  Map<String, String> get primaryOptions {
    final out = <String, String>{for (final s in selectable) s.id: s.name};
    final manager = lxSource?.manager;
    for (final e in manager?.entries ?? const <LxSourceEntry>[]) {
      if (!e.enabled || e.runtime?.loaded != true) continue;
      final platforms = e.defs.values
          .map((d) => '${d['name'] ?? ''}')
          .where((n) => n.isNotEmpty)
          .join('/');
      out['lx:${e.id}'] = platforms.isEmpty ? e.name : '${e.name} · $platforms';
    }
    return out;
  }

  /// 切换播放源时递增，页面据此重新加载。
  int generation = 0;

  String get _fallbackPrimaryId => selectable.isEmpty ? '' : selectable.first.id;

  Future<void> init() async {
    for (final s in sources) {
      await s.init();
      s.addListener(_onSourceChanged);
    }
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_prefsKey);
    if (selectable.isNotEmpty) {
      _current = selectable.firstWhere((s) => s.id == saved, orElse: () => selectable.first);
    }
    final savedPrimary = prefs.getString(_primaryKey);
    _primaryId = _validPrimary(savedPrimary) ? savedPrimary! : _fallbackPrimaryId;
    if (savedPrimary != null && _primaryId != savedPrimary) unawaited(_persistPrimary());
  }

  void _onSourceChanged() {
    // LX 源被删除 / 停用后，主音源回落到默认内置源。
    if (!_validPrimary(_primaryId)) {
      _primaryId = _fallbackPrimaryId;
      unawaited(_persistPrimary());
    }
    generation++;
    DataCache.clear();
    notifyListeners();
  }

  bool _validPrimary(String? id) {
    if (id == null || id.isEmpty) return false;
    if (id.startsWith('lx:')) {
      final e = lxSource?.manager.entryById(id.substring(3));
      return e != null && e.enabled && e.runtime?.loaded == true;
    }
    return selectable.any((s) => s.id == id);
  }

  MusicSource byId(String id) {
    // LX 引擎统一以 'lx'（或 'lx:<platform>'）承载，所有 LX 解析都路由到同一实例。
    if (id.startsWith('lx')) {
      return sources.firstWhere((s) => s.id == LxSource.sourceId, orElse: () => _current);
    }
    return sources.firstWhere((s) => s.id == id, orElse: () => _current);
  }

  /// 便捷获取 LX 源实例（可能尚未注册时返回 null）。
  LxSource? get lxSource => sources.whereType<LxSource>().firstOrNull;

  /// 按主音源决定歌曲实际使用的解析路径。
  ///
  /// 主音源是某个 LX 源、且它支持歌曲所在平台时，返回 `lx:<platform>` 的副本，
  /// 交给 LX 引擎优先解析；否则沿用歌曲自带的源（官方源不受影响）。
  Song songForPlayback(Song song) {
    final entry = primaryLx;
    if (entry == null) return song;
    final platform = _platformOf(song);
    if (platform == null) return song;
    if (!(lxSource?.manager.entrySupports(entry.id, platform, 'musicUrl') ?? false)) return song;
    if (song.sourceId == 'lx:$platform') return song;
    return Song(
      id: song.id,
      sourceId: 'lx:$platform',
      name: song.name,
      artists: song.artists,
      album: song.album,
      duration: song.duration,
      cover: song.cover,
      playable: song.playable,
      alias: song.alias,
      localPath: song.localPath,
      playCount: song.playCount,
    );
  }

  Future<SearchResult> searchPrimary(String keyword, {required SearchType type, int limit = 30}) async {
    final entry = primaryLx;
    if (entry == null) return current.search(keyword, type: type, limit: limit);
    if (type != SearchType.all && type != SearchType.song) return const SearchResult();
    final manager = lxSource!.manager;
    final songs = <Song>[];
    for (final platform in manager.platformsOf(entry.id)) {
      if (!manager.entrySupports(entry.id, platform, 'musicSearch')) continue;
      final items = await manager.searchEntry(entry.id, platform, keyword, limit: limit);
      for (final item in items) {
        manager.cacheInfo(platform, item);
        songs.add(LxSource.songFromLx(platform, item));
      }
    }
    return SearchResult(songs: songs, songCount: songs.length);
  }

  /// 歌曲所属的 LX 平台；官方源目前只映射网易云。
  String? _platformOf(Song song) {
    if (song.sourceId.startsWith('lx:')) return song.sourceId.substring(3);
    if (song.sourceId == 'netease') return 'wy';
    return null;
  }

  /// 选择主音源。[id] 可以是内置源 id，也可以是 `lx:<entryId>`。
  Future<void> select(String id) async {
    if (id == _primaryId) return;
    if (id.startsWith('lx:')) {
      final entry = lxSource?.manager.entryById(id.substring(3));
      if (entry == null || !entry.enabled || entry.runtime?.loaded != true) return;
      _primaryId = id;
      await lxSource!.manager.setPrimary(entry.id);
    } else {
      if (!selectable.any((s) => s.id == id)) return;
      _primaryId = id;
      await lxSource?.manager.setPrimary(null);
      _current = byId(id);
    }
    generation++;
    DataCache.clear();
    notifyListeners();
    await _persistPrimary();
  }

  Future<void> _persistPrimary() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_primaryKey, _primaryId);
    await prefs.setString(_prefsKey, _current.id);
  }

  @override
  void dispose() {
    for (final s in sources) {
      s.removeListener(_onSourceChanged);
    }
    super.dispose();
  }
}
