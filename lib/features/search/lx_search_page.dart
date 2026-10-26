import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models.dart';
import '../../data/sources/lx/lx_engine.dart';
import '../../data/sources/lx/lx_source.dart';
import '../../data/sources/source_manager.dart';
import '../../player/player_controller.dart';

/// LX 跨平台搜索：在导入的音源里按平台检索并直接播放。
///
/// 只有自报 musicSearch 能力的源才会出现在这里（纯解析源如星海不提供搜索，
/// 需换用带搜索能力的 LX 源才能在 QQ / 酷狗等平台直接搜歌）。
class LxSearchPage extends StatefulWidget {
  const LxSearchPage({super.key});

  @override
  State<LxSearchPage> createState() => _LxSearchPageState();
}

class _LxSearchPageState extends State<LxSearchPage> {
  final _controller = TextEditingController();
  LxSourceManager? _manager;
  String? _platform;
  bool _loading = false;
  String? _error;
  List<Song> _songs = const [];

  Map<String, String> get _platforms => _manager?.searchablePlatforms ?? const {};

  @override
  void initState() {
    super.initState();
    _manager = context.read<SourceManager>().lxSource?.manager;
    _manager?.addListener(_onManagerChanged);
    final platforms = _platforms;
    if (platforms.isNotEmpty) _platform = platforms.keys.first;
  }

  @override
  void dispose() {
    _manager?.removeListener(_onManagerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onManagerChanged() {
    if (!mounted) return;
    setState(() {
      final platforms = _platforms;
      if (_platform == null || !platforms.containsKey(_platform)) {
        _platform = platforms.isEmpty ? null : platforms.keys.first;
      }
    });
  }

  Future<void> _search() async {
    final manager = _manager;
    final platform = _platform;
    final keyword = _controller.text.trim();
    if (manager == null || platform == null || keyword.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _songs = const [];
    });
    try {
      final items = await manager.search(platform, keyword);
      final songs = <Song>[];
      for (final item in items) {
        manager.cacheInfo(platform, item);
        songs.add(LxSource.songFromLx(platform, item));
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _songs = songs;
        if (songs.isEmpty) _error = '没有搜到结果';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '搜索失败：$e';
      });
    }
  }

  void _play(int index) {
    final platform = _platform;
    if (platform == null) return;
    final player = context.read<PlayerController>();
    player.playSongs(_songs, start: index, title: '${_platforms[platform]} 搜索');
  }

  @override
  Widget build(BuildContext context) {
    final platforms = _platforms;
    return Scaffold(
      appBar: AppBar(title: const Text('LX 搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                DropdownButton<String>(
                  value: _platform,
                  hint: const Text('平台'),
                  items: [for (final e in platforms.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
                  onChanged: (v) => setState(() => _platform = v),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: const InputDecoration(hintText: '歌曲 / 歌手', isDense: true, border: OutlineInputBorder()),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(icon: const Icon(Icons.search), onPressed: _search),
              ],
            ),
          ),
          if (platforms.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('导入的音源都没有声明 musicSearch 能力\n请换用带搜索能力的 LX 源', textAlign: TextAlign.center)),
            )
          else
            Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)),
      );
    }
    if (_songs.isEmpty) {
      return const Center(child: Text('输入关键词开始搜索'));
    }
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: _songs.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final song = _songs[i];
        return ListTile(
          leading: _Cover(url: song.coverUrl),
          title: Text(song.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(song.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
          onTap: () => _play(i),
        );
      },
    );
  }
}

class _Cover extends StatelessWidget {
  const _Cover({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    if (url == null || url!.isEmpty) {
      return const SizedBox(width: 44, height: 44, child: Icon(Icons.music_note));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image.network(
        url!,
        width: 44,
        height: 44,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => const SizedBox(width: 44, height: 44, child: Icon(Icons.music_note)),
      ),
    );
  }
}
