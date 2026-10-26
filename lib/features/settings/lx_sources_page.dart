import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../data/sources/lx/lx_engine.dart';
import '../../data/sources/source_manager.dart';
import '../common/actions.dart';
import '../shell/nav.dart';

/// LX 音源管理：导入 / 启用 / 删除 LX 音乐源 JS 文件。
///
/// 源在独立的 JS 运行时中执行（QuickJS / JSC），只能使用宿主提供的 lx 接口，
/// 不接触文件系统与网络以外的能力。星海等第三方源均通过“导入”接入，应用不预置任何源。
class LxSourcesPage extends StatefulWidget {
  const LxSourcesPage({super.key});

  @override
  State<LxSourcesPage> createState() => _LxSourcesPageState();
}

class _LxSourcesPageState extends State<LxSourcesPage> {
  LxSourceManager? _manager;

  @override
  void initState() {
    super.initState();
    _manager = context.read<SourceManager>().lxSource?.manager;
    _manager?.addListener(_onChanged);
  }

  @override
  void dispose() {
    _manager?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _import() async {
    // file_picker 12 起 FilePicker.platform 已移除，直接用静态方法。
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['js'],
    );
    if (file == null) return;
    final path = file.path;
    if (path == null || _manager == null) return;
    try {
      final entry = await _manager!.importSource(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导入 ${entry.name}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Future<void> _confirmRemove(LxSourceEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除音源'),
        content: Text('确定删除「${entry.name}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) await _manager?.removeSource(entry.id);
  }

  @override
  Widget build(BuildContext context) {
    final manager = _manager;
    final settings = context.watch<AppSettings>();
    final entries = manager?.entries ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('LX 音源')),
      body: manager == null
          ? const Center(child: Text('LX 引擎未初始化'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                const SizedBox(height: 4),
                Text(
                  '导入 LX 音乐源的 .js 文件即可启用解析。多个源支持同一平台时按顺序兜底。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    FilledButton.icon(
                      onPressed: _import,
                      icon: const Icon(Icons.add),
                      label: const Text('导入音源'),
                    ),
                    if (manager.searchablePlatforms.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: () => go(context, LxSearchRoute()),
                        icon: const Icon(Icons.search),
                        label: const Text('跨平台搜索'),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                if (entries.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: Text('还没有导入任何音源')),
                  ),
                for (final e in entries) _SourceTile(entry: e, onToggle: (v) => manager.setEnabled(e.id, v), onRemove: () => _confirmRemove(e)),
                const SizedBox(height: 20),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('网易云播放失败时自动兜底'),
                  subtitle: const Text('官方源取不到地址时，用已导入的 LX 源在网易云平台再解析一次'),
                  value: settings.lxFallback,
                  onChanged: (v) => settings.setFlag('lxFallback', v),
                ),
                const SizedBox(height: 8),
                Text(
                  '音源脚本在隔离的 JS 运行时内执行，仅能调用宿主提供的网络与事件接口。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey[600]),
                ),
              ],
            ),
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({required this.entry, required this.onToggle, required this.onRemove});

  final LxSourceEntry entry;
  final ValueChanged<bool> onToggle;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final defs = entry.defs;
    final platforms = defs.values.map((d) => '${d['name'] ?? ''}').where((s) => s.isNotEmpty).toList();
    final loaded = entry.runtime?.loaded == true;
    final subtitle = loaded
        ? (platforms.isEmpty ? '已加载，未声明平台' : platforms.join(' / '))
        : '加载失败';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(entry.name),
        subtitle: Text(subtitle),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(value: entry.enabled, onChanged: onToggle),
            IconButton(icon: const Icon(Icons.delete_outline), onPressed: onRemove),
          ],
        ),
      ),
    );
  }
}
