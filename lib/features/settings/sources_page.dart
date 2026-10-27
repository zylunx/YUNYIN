import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/settings.dart';
import '../../data/sources/lx/lx_engine.dart';
import '../../data/sources/source_manager.dart';
import '../common/actions.dart';
import '../shell/nav.dart';

/// 音源：选择主音源，并导入 / 启用 / 删除 LX 音乐源 JS 文件。
///
/// 内置源与导入的 LX 源合并在同一个列表里。选中某个源后，播放会优先使用它：
/// 同一平台有多个 LX 源时，选中的源排在最前，其余按导入顺序兜底。
///
/// 源在独立的 JS 运行时中执行（QuickJS / JSC），只能使用宿主提供的 lx 接口，
/// 不接触文件系统与网络以外的能力。星海等第三方源均通过“导入”接入，应用不预置任何源。
class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key});

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  Future<void> _import(SourceManager sm) async {
    final manager = sm.lxSource?.manager;
    // file_picker 12 起 FilePicker.platform 已移除，直接用静态方法。
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: const ['js'],
    );
    if (file == null) return;
    final path = file.path;
    if (path == null || manager == null) return;
    try {
      final entry = await manager.importSource(path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导入 ${entry.name}')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Future<void> _confirmRemove(LxSourceManager manager, LxSourceEntry entry) async {
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
    if (ok == true) await manager.removeSource(entry.id);
  }

  void _select(SourceManager sm, String id) {
    if (id == sm.primaryId) return;
    unawaited(sm.select(id).then((_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已切换到 ${sm.primaryName}')));
    }));
  }

  @override
  Widget build(BuildContext context) {
    final sm = context.watch<SourceManager>();
    final manager = sm.lxSource?.manager;
    final entries = manager?.entries ?? const <LxSourceEntry>[];
    final settings = context.watch<AppSettings>();

    return Scaffold(
      appBar: AppBar(title: const Text('音源')),
      body: manager == null
          ? const Center(child: Text('LX 引擎未初始化'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                const SizedBox(height: 4),
                Text(
                  '选中的音源会作为主音源：播放时优先用它解析，同一平台的其他 LX 源按导入顺序兜底。',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: Colors.grey[700]),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: () => _import(sm),
                      icon: const Icon(Icons.add),
                      label: const Text('导入音源'),
                    ),
                    if (manager.searchablePlatforms.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: () => go(context, LxSearchRoute()),
                        icon: const Icon(Icons.search),
                        label: const Text('跨平台搜索'),
                      ),
                  ],
                ),
                const SizedBox(height: 20),
                Text('主音源', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (final s in sm.selectable)
                        ListTile(
                          leading: _Check(selected: sm.primaryId == s.id),
                          title: Text(s.name),
                          subtitle: Text(s.description),
                          onTap: () => _select(sm, s.id),
                        ),
                      for (final e in entries) _entryTile(sm, manager, e),
                      if (sm.selectable.isEmpty && entries.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text('还没有可用的音源'),
                        ),
                    ],
                  ),
                ),
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

  Widget _entryTile(SourceManager sm, LxSourceManager manager, LxSourceEntry entry) {
    final platforms = entry.defs.values.map((d) => '${d['name'] ?? ''}').where((s) => s.isNotEmpty).toList();
    final loaded = entry.runtime?.loaded == true;
    final canSelect = entry.enabled && loaded;
    final subtitle = loaded
        ? (platforms.isEmpty ? '已加载，未声明平台' : platforms.join(' / '))
        : '加载失败';
    return ListTile(
      leading: _Check(selected: sm.primaryId == 'lx:${entry.id}', enabled: canSelect),
      title: Text(entry.name),
      subtitle: Text(subtitle),
      enabled: canSelect,
      onTap: canSelect ? () => _select(sm, 'lx:${entry.id}') : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(value: entry.enabled, onChanged: (v) => manager.setEnabled(entry.id, v)),
          IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _confirmRemove(manager, entry)),
        ],
      ),
    );
  }
}

/// 主音源选中标记。
class _Check extends StatelessWidget {
  const _Check({required this.selected, this.enabled = true});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? Theme.of(context).colorScheme.primary : Theme.of(context).disabledColor;
    return Icon(selected ? Icons.check_circle : Icons.radio_button_unchecked, color: color);
  }
}
