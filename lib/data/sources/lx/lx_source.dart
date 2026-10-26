import 'package:flutter/foundation.dart';

import '../../lyrics.dart';
import '../../models.dart';
import '../music_source.dart';
import 'lx_engine.dart';

/// 把通用 LX 引擎包装成一个 [MusicSource]，供播放器在“换音源”或“官方源失败兜底”时调用。
///
/// 它本身不是目录源（不提供搜索/歌单），故 [selectable] 为 false；播放器通过
/// 把歌曲的 [Song.sourceId] 设为 `lx:<platform>` 来指定用哪个平台解析。
class LxSource extends MusicSource {
  LxSource(this.manager);

  static const sourceId = 'lx';

  final LxSourceManager manager;

  @override
  String get id => sourceId;

  @override
  String get name => 'LX 音源';

  @override
  String get description => '由 LX 音乐源引擎解析的播放地址';

  @override
  Set<SourceFeature> get features => {SourceFeature.lyrics};

  @override
  bool get selectable => false;

  /// 从 `lx:<platform>` 形式的 sourceId 解析平台；缺省按网易云处理。
  static String platformOf(String sourceId) {
    if (sourceId.startsWith('lx:')) return sourceId.substring(3);
    return 'wy';
  }

  /// 由 [Song] 构造 LX 源所需的 musicInfo。网易云歌曲天然带 id，可直接解析。
  static Map<String, dynamic> musicInfoOf(Song song) => {
        'id': song.id,
        'name': song.name,
        'singer': song.artistText,
        'interval': '${song.duration.inSeconds}',
        'albumName': song.albumName,
        'hash': null,
        'songmid': null,
      };

  /// 把 LX 搜索返回的 musicInfo 转成 [Song]；平台标识写入 sourceId（`lx:<platform>`）。
  static Song songFromLx(String platform, Map<String, dynamic> item) {
    final id = '${item['id'] ?? item['songmid'] ?? item['hash'] ?? ''}';
    final singer = '${item['singer'] ?? item['artist'] ?? ''}';
    final artists = [
      for (final n in singer.split(RegExp(r'[、,，/]')))
        if (n.trim().isNotEmpty) ArtistRef('', n.trim())
    ];
    final album = '${item['albumName'] ?? item['album'] ?? ''}';
    final pic = item['picUrl'] ?? item['img'] ?? item['pic'] ?? item['cover'];
    final cover = pic == null ? null : '$pic';
    return Song(
      id: id,
      sourceId: 'lx:$platform',
      name: '${item['name'] ?? ''}',
      artists: artists,
      album: album.isEmpty ? null : AlbumRef('${item['albumId'] ?? ''}', album, cover: cover),
      duration: Duration(seconds: _seconds(item['interval'])),
      cover: cover,
    );
  }

  /// interval 可能是秒数，也可能是 'mm:ss'。
  static int _seconds(Object? v) {
    if (v is num) return v.toInt() < 0 ? 0 : v.toInt();
    final s = '$v';
    final n = int.tryParse(s);
    if (n != null) return n < 0 ? 0 : n;
    final parts = s.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0].trim());
      final sec = int.tryParse(parts[1].trim());
      if (m != null && sec != null) return m * 60 + sec;
    }
    return 0;
  }

  /// 把 [AudioQuality] 映射到 LX 音质串；源内部还会按平台可用性再降级。
  static String qualityOf(AudioQuality q) {
    switch (q) {
      case AudioQuality.standard:
        return '128k';
      case AudioQuality.higher:
      case AudioQuality.exhigh:
        return '320k';
      case AudioQuality.lossless:
        return 'flac';
      case AudioQuality.hires:
        return 'hires';
    }
  }

  @override
  Future<StreamInfo> stream(Song song, AudioQuality quality) async {
    final platform = platformOf(song.sourceId);
    // 搜索得到的歌曲带完整 musicInfo（含 hash / songmid / _types），优先使用。
    final info = manager.infoFor(platform, song.id) ?? musicInfoOf(song);
    final url = await manager.resolveUrl(platform, info, qualityOf(quality));
    if (url == null) return const StreamInfo();
    return StreamInfo(url: url, quality: quality);
  }

  @override
  Future<Lyrics> lyrics(Song song) async {
    final platform = platformOf(song.sourceId);
    final info = manager.infoFor(platform, song.id) ?? musicInfoOf(song);
    final data = await manager.resolveLyric(platform, info);
    if (data == null) return Lyrics.empty;
    final lrc = (data['lyric'] as String?) ?? '';
    final tr = (data['tlyric'] as String?) ?? '';
    if (lrc.isEmpty) return Lyrics.empty;
    return parseLrc(lrc, translation: tr);
  }
}

