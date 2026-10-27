import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../settings.dart';
import 'adaptive_scale.dart';

/// 液态玻璃着色器（shaders/liquid_glass.frag）。只在 Impeller 下可用，其他渲染后端退回普通毛玻璃。
abstract final class LiquidGlassShader {
  static ui.FragmentProgram? _program;

  static bool get available => _program != null;

  static Future<void> init() async {
    if (kIsWeb || !ui.ImageFilter.isShaderFilterSupported) return;
    try {
      _program = await ui.FragmentProgram.fromAsset('shaders/liquid_glass.frag');
    } catch (e) {
      debugPrint('liquid glass shader: $e');
    }
  }
}

/// 在子组件背后用液态玻璃着色器处理背景。
///
/// 「清透」只有一层着色器滤镜，通过 [BackdropGroup] 与同画面的其他玻璃共用一次背景截取，
/// 着色器按输入纹理尺寸判断坐标系，因此需要玻璃在画面中的位置：每次绘制时写入，
/// 位置因祖先变换变化时下一帧补绘。
///
/// 「柔和」不参与共享背景截取：共享纹理属于更外层的那次截取，而玻璃自身图层的
/// `FlutterFragCoord` 以当前图层为原点，两者坐标系不一致，会在玻璃外多画出一块矩形底色。
/// 因此把「模糊 + 着色器」合并成一个滤镜，在玻璃自己的图层里截取背景、一次完成。
class LiquidGlassBackdrop extends SingleChildRenderObjectWidget {
  const LiquidGlassBackdrop({super.key, required this.radius, required this.material, super.child});

  final double radius;
  final GlassMaterial material;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderLiquidGlass(radius, material, MediaQuery.devicePixelRatioOf(context), BackdropGroup.of(context)?.backdropKey, AdaptiveScale.of(context));

  @override
  void updateRenderObject(BuildContext context, RenderLiquidGlass renderObject) {
    renderObject
      ..radius = radius
      ..material = material
      ..dpr = MediaQuery.devicePixelRatioOf(context)
      ..backdropKey = BackdropGroup.of(context)?.backdropKey
      ..uiScale = AdaptiveScale.of(context);
  }
}

/// [LiquidGlassBackdrop] 的渲染对象。
class RenderLiquidGlass extends RenderProxyBox {
  RenderLiquidGlass(this._radius, this._material, this._dpr, this._backdropKey, this._uiScale);

  /// 裁剪区域比玻璃每边多出的逻辑像素。
  static const _pad = 1.0;

  /// 「柔和」的高斯模糊半径（原版以 1 倍屏像素设计，sigma = 30 / 3）。
  static const _regularSigma = 10.0;

  double _radius;
  GlassMaterial _material;
  double _dpr;
  BackdropKey? _backdropKey;

  /// 界面缩放倍数：全局坐标是缩放后的屏幕坐标，换算物理像素时要除去这一倍数。
  double _uiScale;
  Offset? _painted;
  bool _checkScheduled = false;
  ui.FragmentShader? _shader;
  final _clip = LayerHandle<ClipRectLayer>();
  final _glass = LayerHandle<BackdropFilterLayer>();

  set radius(double v) {
    if (v == _radius) return;
    _radius = v;
    markNeedsPaint();
  }

  set material(GlassMaterial v) {
    if (v == _material) return;
    _material = v;
    markNeedsPaint();
  }

  set dpr(double v) {
    if (v == _dpr) return;
    _dpr = v;
    markNeedsPaint();
  }

  set uiScale(double v) {
    if (v == _uiScale) return;
    _uiScale = v;
    markNeedsPaint();
  }

  set backdropKey(BackdropKey? v) {
    if (v == _backdropKey) return;
    _backdropKey = v;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  void dispose() {
    _clip.layer = null;
    _glass.layer = null;
    _shader?.dispose();
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final global = localToGlobal(Offset.zero);
    _painted = global;
    _scheduleCheck();

    _shader?.dispose();
    final shader = _shader = LiquidGlassShader._program!.fragmentShader();
    final regular = _material == GlassMaterial.regular;
    var i = 2; // 0、1 是输入纹理尺寸，由引擎填写。
    void f(double v) => shader.setFloat(i++, v);
    f(size.width * _dpr);
    f(size.height * _dpr);
    f(_radius * _dpr);
    f(_dpr);
    f(20); // 边缘厚度
    f(1); // 折射强度 100%
    f(7); // 色散
    f(0.9); // 边缘高光 90%
    f(0); // 色调：两种材质都不再叠白色底，柔和的可读性靠模糊
    // 圆角达到短边一半（圆形、胶囊）时用正圆弧，否则用原版面板的超椭圆圆角。
    f(_radius >= size.shortestSide / 2 - 0.5 ? 2 : 5);
    f(global.dx * _dpr / _uiScale);
    f(global.dy * _dpr / _uiScale);
    f(_pad * _dpr);

    // 「柔和」先模糊再交给着色器；两层合并成同一个滤镜，避免多一层背景滤镜
    // 把着色器的坐标系换成上一层图层的坐标。
    final filter = regular
        ? ui.ImageFilter.compose(
            outer: ui.ImageFilter.shader(shader),
            inner: ui.ImageFilter.blur(sigmaX: _regularSigma, sigmaY: _regularSigma, tileMode: TileMode.clamp),
          )
        : ui.ImageFilter.shader(shader);
    // 「柔和」在自己的图层里截取背景（不共享），坐标与玻璃对齐；
    // 「清透」继续复用 [BackdropGroup] 的那次全屏截取。
    final backdropKey = regular ? null : _backdropKey;

    _clip.layer = context.pushClipRect(needsCompositing, offset, (Offset.zero & size).inflate(_pad), (context, offset) {
      final layer = _glass.layer ??= BackdropFilterLayer();
      layer
        ..filter = filter
        ..backdropKey = backdropKey;
      context.pushLayer(layer, super.paint, offset);
    }, oldLayer: _clip.layer);
  }

  void _scheduleCheck() {
    if (_checkScheduled) return;
    _checkScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      if (!attached || _painted == null) return;
      if ((localToGlobal(Offset.zero) - _painted!).distanceSquared > 0.01) markNeedsPaint();
    });
  }
}
