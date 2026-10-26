import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/theme/palette.dart';
import '../../core/ui/box.dart';
import '../../core/ui/cover.dart';
import '../../core/ui/icons.dart';
import '../../core/ui/text.dart';
import '../../core/ui/widgets.dart';
import '../../player/player_controller.dart';
import '../common/actions.dart';
import '../common/layout.dart';
import 'nav.dart';
import 'routes.dart';

/// 移动端外壳：三个标签各自的导航栈 + 悬浮玻璃导航栏与迷你播放条。
class MobileShell extends StatefulWidget {
  const MobileShell({super.key});

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  final _keys = List.generate(3, (_) => GlobalKey<NavigatorState>());

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<AppNav>();
    final chrome = nav.top.chrome;
    final bottom = chromeBottom(context);
    final hasSong = context.select<PlayerController, bool>((p) => p.current != null);
    final showNav = chrome == Chrome.full || chrome == Chrome.navOnly;
    final showMini = hasSong && (chrome == Chrome.full || chrome == Chrome.miniOnly);

    // 横屏或平板上导航栏与迷你播放条不必铺满整行，限制在 560 宽并居中。
    final barInset = math.max(0.0, (MediaQuery.sizeOf(context).width - 560) / 2);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) nav.handleBack();
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: _TabSlideSwitcher(
              index: nav.tab,
              children: [
                for (var i = 0; i < 3; i++)
                  Navigator(
                    key: _keys[i],
                    pages: [for (final r in nav.stacks[i]) CupertinoPage<void>(key: ValueKey(r.uid), child: buildMobileRoute(r))],
                    onDidRemovePage: (page) {
                      final key = page.key;
                      if (key is ValueKey<int>) {
                        final r = nav.stacks[i].where((x) => x.uid == key.value).firstOrNull;
                        if (r != null) nav.removed(i, r);
                      }
                    },
                  ),
              ],
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            left: 12 + barInset,
            right: 12 + barInset,
            bottom: chrome == Chrome.miniOnly ? bottom + 2 : bottom + 74,
            child: IgnorePointer(
              ignoring: !showMini,
              child: AnimatedOpacity(opacity: showMini ? 1 : 0, duration: const Duration(milliseconds: 200), child: const MiniPlayer()),
            ),
          ),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            left: 16 + barInset,
            right: 16 + barInset,
            bottom: showNav ? bottom : -100,
            child: const _BottomBar(),
          ),
        ],
      ),
    );
  }
}

/// Q弹曲线（图标用）：阻尼振荡，过冲约 12%，回弹明显。
class _QBounce extends Curve {
  const _QBounce();

  @override
  double transform(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return (1 - math.pow(math.e, -5.2 * t) * math.cos(7.6 * t)).toDouble();
  }
}

/// 页面滑动曲线：同样是阻尼振荡，但过冲只有约 4%，
/// 避免整页位移过冲过大显得拖沓。
class _QSlide extends Curve {
  const _QSlide();

  @override
  double transform(double t) {
    if (t <= 0) return 0;
    if (t >= 1) return 1;
    return (1 - math.pow(math.e, -6.5 * t) * math.cos(6.2 * t)).toDouble();
  }
}

/// 标签页切换：新页从侧边滑入、旧页反向滑出，曲线带回弹。
///
/// 三个 Navigator 常驻在树里（不可见的用 [Offstage] 隐藏），保证各自的导航栈状态不丢。
class _TabSlideSwitcher extends StatefulWidget {
  const _TabSlideSwitcher({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_TabSlideSwitcher> createState() => _TabSlideSwitcherState();
}

class _TabSlideSwitcherState extends State<_TabSlideSwitcher> with SingleTickerProviderStateMixin {
  static const _curve = _QSlide();

  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 460))..value = 1;
  late int _prev;
  int _dir = 1;

  @override
  void initState() {
    super.initState();
    _prev = widget.index;
  }

  @override
  void didUpdateWidget(covariant _TabSlideSwitcher old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) {
      _dir = widget.index > old.index ? 1 : -1;
      _prev = old.index;
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  double _offsetFor(int i, double width, double t) {
    if (i == widget.index) return _dir * (1 - t) * width;
    if (i == _prev && _c.isAnimating) return -_dir * t * width;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _curve.transform(_c.value);
        return Stack(
          children: [
            for (var i = 0; i < widget.children.length; i++)
              Positioned.fill(
                child: Offstage(
                  offstage: i != widget.index && !(i == _prev && _c.isAnimating),
                  child: Transform.translate(
                    offset: Offset(_offsetFor(i, width, t), 0),
                    child: widget.children[i],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar();

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final nav = context.watch<AppNav>();
    return Row(
      children: [
        Expanded(
          child: Semantics(
            label: '主导航',
            container: true,
            child: Glass(
              radius: 32,
              height: 64,
              padding: const EdgeInsets.all(5),
              child: Row(
                children: [
                  _NavItem(icon: YIcons.home, label: '首页', active: nav.tab == 0, onTap: () => nav.switchTab(0)),
                  _NavItem(icon: YIcons.discover, label: '发现', active: nav.tab == 1, onTap: () => nav.switchTab(1)),
                  _NavItem(icon: YIcons.library, label: '乐库', active: nav.tab == 2, onTap: () => nav.switchTab(2)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Pressable(
          onTap: () => nav.push(SearchRoute()),
          scale: 0.94,
          semanticLabel: '搜索',
          child: Glass(
            radius: 32,
            width: 64,
            height: 64,
            alignment: Alignment.center,
            child: YIcon(YIcons.search, size: 24, color: p.text),
          ),
        ),
      ],
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({required this.icon, required this.label, required this.active, required this.onTap});

  final YIconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 480));
  late final Animation<double> _a = CurvedAnimation(parent: _c, curve: const _QBounce());

  @override
  void didUpdateWidget(covariant _NavItem old) {
    super.didUpdateWidget(old);
    // 选中瞬间回弹一下；取消选中不播动画。
    if (widget.active && !old.active) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// 静止时保持 1；动画中从 0.7 弹到 1，配合曲线过冲形成“Q弹”手感。
  double get _scale => (_c.isAnimating || _c.value > 0) ? 0.7 + 0.3 * _a.value : 1.0;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final color = widget.active ? p.accentText : p.text3;
    final active = widget.active;
    return Expanded(
      child: Pressable(
        onTap: widget.onTap,
        scale: 0.96,
        semanticLabel: widget.label,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          decoration: BoxDecoration(color: active ? p.navActive : Colors.transparent, borderRadius: BorderRadius.circular(27)),
          child: CustomPaint(
            foregroundPainter: active ? InsetShadowPainter(BorderRadius.circular(27), [Shadow2(0, 0.5, 1, p.navActiveInset)]) : null,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedBuilder(
                  animation: _a,
                  builder: (_, __) => Transform.scale(scale: _scale, child: YIcon(widget.icon, size: 22, color: color)),
                ),
                const SizedBox(height: 3),
                Text(
                  widget.label,
                  style: ts(11, weight: active ? w600 : w500, color: color, height: 1.2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 迷你播放条（高 58，玻璃）。
class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final player = context.watch<PlayerController>();
    final song = player.current;
    return Glass(
      radius: 29,
      height: 58,
      padding: const EdgeInsets.fromLTRB(7, 7, 8, 7),
      child: Row(
        children: [
          Expanded(
            child: Pressable(
              onTap: () => openPlayer(context),
              scale: 1,
              child: Row(
                children: [
                  Cover(song?.coverUrl, size: 42, circle: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song?.name ?? '',
                          style: ts(14, weight: w600, color: p.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          song?.artistText ?? '',
                          style: ts(12, color: p.text4),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          YIconButton(player.playing ? YIcons.pause : YIcons.play, label: player.playing ? '暂停' : '播放', onTap: player.toggle),
          YIconButton(YIcons.next, label: '下一首', onTap: player.next),
        ],
      ),
    );
  }
}
