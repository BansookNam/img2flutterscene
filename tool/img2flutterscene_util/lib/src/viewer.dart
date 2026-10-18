import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';
import 'package:img2flutterscene/img2flutterscene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'view_settings.dart';

/// The 3D preview: one scene description on an orbit camera.
///
/// Mouse: drag = orbit, right/middle-drag or shift-drag = pan, wheel = zoom,
/// double-click = reset. Trackpad: two-finger drag = orbit, pinch = zoom.
/// Keys (click the view first): F R B L T = front/right/back/left/top,
/// 0 = reset, W = wireframe, G = grid, Space = auto-rotate.
class ModelViewer extends StatefulWidget {
  const ModelViewer({
    super.key,
    required this.scene,
    required this.settings,
    required this.orbit,
    required this.shotKey,
  });

  final SceneDescription scene;
  final ViewSettings settings;
  final OrbitController orbit;

  /// Wraps the rendered frame only, for screenshots.
  final GlobalKey shotKey;

  @override
  State<ModelViewer> createState() => _ModelViewerState();
}

class _ModelViewerState extends State<ModelViewer> {
  final Scene _scene = Scene();
  final Node _gridNode = Node(name: 'grid');
  final FocusNode _focus = FocusNode();

  /// One light, updated in place: assigning Scene.directionalLight swaps a
  /// component on the scene root, which is not a per-frame operation.
  final DirectionalLight _light = DirectionalLight(color: vm.Vector3(1, 0.97, 0.92));
  SculptModel? _model;
  vm.Vector3 _centre = vm.Vector3.zero();
  double _radius = 1;
  double _floor = 0;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_applySettings);
    _init();
  }

  Future<void> _init() async {
    try {
      await Scene.initializeStaticResources();
    } catch (e) {
      setState(() => _error = 'Flutter GPU is unavailable: $e');
      return;
    }
    _scene.directionalLight = _light;
    // The grid keeps its own look under every inspection view.
    _gridNode.debugView = DebugView.none;
    _scene.add(_gridNode);
    _load();
    if (mounted) setState(() => _ready = true);
  }

  @override
  void didUpdateWidget(ModelViewer old) {
    super.didUpdateWidget(old);
    if (old.settings != widget.settings) {
      old.settings.removeListener(_applySettings);
      widget.settings.addListener(_applySettings);
    }
    if (_ready && !identical(old.scene, widget.scene)) _load();
  }

  void _load() {
    final old = _model;
    if (old != null) _scene.remove(old.node);
    try {
      final model = loadSceneDescription(widget.scene);
      _scene.add(model.node);
      _model = model;
      _error = null;
      final b = model.node.combinedLocalBounds;
      if (b != null) {
        _centre = (b.min + b.max) * 0.5;
        _radius = math.max((b.max - b.min).length * 0.5, 1e-3);
        _floor = b.min.y;
      }
      _rebuildGrid();
      _applySettings();
    } catch (e) {
      _model = null;
      _error = 'Could not build the model: $e';
    }
  }

  void _rebuildGrid() {
    // A floor grid under the model: a 1/2/5 step giving ~10 cells across it.
    final step = _niceStep(_radius / 4);
    const n = 10;
    final half = step * n;
    final w = step * 0.02;
    final y = _floor - _radius * 0.002;
    final b = PartBuilder();
    void strip(vm.Vector3 a, vm.Vector3 c, vm.Vector3 side, vm.Vector4 color) {
      final up = vm.Vector3(0, 1, 0);
      b.patch(
        [
          [a - side, c - side],
          [a + side, c + side],
        ],
        (_, _) => up,
        (_, _) => color,
      );
    }

    for (var i = -n; i <= n; i++) {
      final t = i * step;
      final minor = lin(0xFF3A3F4A);
      strip(
        vm.Vector3(_centre.x + t, y, _centre.z - half),
        vm.Vector3(_centre.x + t, y, _centre.z + half),
        vm.Vector3(w, 0, 0),
        i == 0 ? lin(0xFF4060C0) : minor,
      );
      strip(
        vm.Vector3(_centre.x - half, y, _centre.z + t),
        vm.Vector3(_centre.x + half, y, _centre.z + t),
        vm.Vector3(0, 0, w),
        i == 0 ? lin(0xFFC04040) : minor,
      );
    }
    _gridNode.mesh = Mesh(b.build(), UnlitMaterial()..vertexColorWeight = 1);
  }

  static double _niceStep(double raw) {
    final decade = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final m = raw / decade;
    return decade * (m >= 5 ? 5 : (m >= 2 ? 2 : 1));
  }

  void _applySettings() {
    final s = widget.settings;
    final model = _model;
    _gridNode.visible = s.grid;
    _scene
      ..environmentIntensity = s.environmentIntensity
      ..environmentSettings = EnvironmentSettings(
        toneMapping: s.toneMapping ? ToneMappingMode.aces : ToneMappingMode.pbrNeutral,
        exposure: s.exposure,
      );
    _scene.debug.view = s.view == InspectView.lit ? DebugView.none : DebugView(channel: s.view.channel);
    if (s.wireframe) {
      _scene.debug.overlays.add(DebugOverlay.wireframe);
    } else {
      _scene.debug.overlays.remove(DebugOverlay.wireframe);
    }
    final focus = s.focusRequest;
    if (focus != null && model != null) {
      s.focusRequest = null; // consumed without notifying: no rebuild loop
      final b = model.meshOf(focus)?.combinedWorldBounds;
      if (b != null) {
        final partRadius = math.max((b.max - b.min).length * 0.5, _radius * 0.02);
        widget.orbit.frame((b.min + b.max) * 0.5 - _centre, (partRadius / _radius * 1.6).clamp(0.05, 1.0));
      }
    }
    if (model != null) {
      model.explode(s.explode * _radius);
      for (final id in model.nodes.keys) {
        final mesh = model.meshOf(id);
        if (mesh == null) continue;
        final selected = id == s.selected;
        mesh.visible = !s.hidden.contains(id) && (!s.isolate || s.selected == null || selected);
        mesh.debugView = selected && s.tintSelected && s.view == InspectView.lit
            ? const DebugView(channel: SurfaceDebugChannel.objectColor)
            : null;
      }
    }
  }

  void _tick(Duration elapsed, double dt) {
    final s = widget.settings;
    if (s.autoRotate) widget.orbit.orbit(dt * 0.5, 0);
    _light
      ..direction = s.lightDirection(widget.orbit.yaw)
      ..intensity = s.keyIntensity;
  }

  double _fitDistance(Size size) {
    final fovY = widget.settings.fovDegrees * vm.degrees2Radians;
    final aspect = size.width / math.max(size.height, 1);
    final fovX = 2 * math.atan(math.tan(fovY / 2) * aspect);
    return _radius / math.sin(math.min(fovY, fovX) / 2) * 1.1;
  }

  void _panPixels(Offset delta, Size size) {
    final o = widget.orbit;
    final eye = o.eyeDirection;
    final right = screenRight(o.yaw);
    final up = right.cross(eye)..normalize();
    final worldPerPixel =
        _fitDistance(size) * o.zoom * 2 * math.tan(widget.settings.fovDegrees * vm.degrees2Radians / 2) / size.height;
    // The model follows the cursor: the target moves the other way.
    o.panBy((right * -delta.dx + up * delta.dy) * worldPerPixel);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final o = widget.orbit;
    final s = widget.settings;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.keyF:
        o.preset(0, 0);
      case LogicalKeyboardKey.keyR:
        o.preset(90, 0);
      case LogicalKeyboardKey.keyB:
        o.preset(180, 0);
      case LogicalKeyboardKey.keyL:
        o.preset(270, 0);
      case LogicalKeyboardKey.keyT:
        o.preset(0, 89);
      case LogicalKeyboardKey.digit0:
        o.reset();
      case LogicalKeyboardKey.keyW:
        s.update((s) => s.wireframe = !s.wireframe);
      case LogicalKeyboardKey.keyG:
        s.update((s) => s.grid = !s.grid);
      case LogicalKeyboardKey.space:
        s.update((s) => s.autoRotate = !s.autoRotate);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
      );
    }
    if (!_ready) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(
      builder: (context, box) {
        final size = box.biggest;
        return Focus(
          focusNode: _focus,
          onKeyEvent: _onKey,
          child: Listener(
            onPointerDown: (_) => _focus.requestFocus(),
            onPointerMove: (e) {
              final shift = HardwareKeyboard.instance.isShiftPressed;
              if (e.buttons & (kSecondaryMouseButton | kMiddleMouseButton) != 0 ||
                  (shift && e.buttons & kPrimaryMouseButton != 0)) {
                _panPixels(e.delta, size);
              } else if (e.buttons & kPrimaryMouseButton != 0) {
                widget.orbit.orbit(-e.delta.dx * 0.008, e.delta.dy * 0.008);
              }
            },
            onPointerSignal: (e) {
              if (e is PointerScrollEvent) widget.orbit.zoomBy(math.exp(e.scrollDelta.dy * 0.002));
            },
            onPointerPanZoomUpdate: (e) {
              if (e.scale != 1) widget.orbit.zoomBy(1 / math.pow(e.scale, 0.15));
              widget.orbit.orbit(-e.panDelta.dx * 0.008, e.panDelta.dy * 0.008);
            },
            child: GestureDetector(
              onDoubleTap: widget.orbit.reset,
              child: ListenableBuilder(
                listenable: Listenable.merge([widget.orbit, widget.settings]),
                builder: (context, _) {
                  final o = widget.orbit;
                  final target = _centre + o.pan;
                  final distance = _fitDistance(size) * o.zoom;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
                        key: widget.shotKey,
                        child: ColoredBox(
                          color: widget.settings.backdrop.color,
                          child: SceneView(
                            _scene,
                            camera: PerspectiveCamera(
                              position: target + o.eyeDirection * distance,
                              target: target,
                              fovRadiansY: widget.settings.fovDegrees * vm.degrees2Radians,
                              fovNear: math.max(distance * 0.002, 1e-4),
                              fovFar: distance * 50 + _radius * 10,
                            ),
                            onTick: _tick,
                          ),
                        ),
                      ),
                      const Positioned(left: 10, bottom: 8, child: _ControlsHint()),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    widget.settings.removeListener(_applySettings);
    _focus.dispose();
    super.dispose();
  }
}

class _ControlsHint extends StatelessWidget {
  const _ControlsHint();

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: Text(
      'Drag orbit · Shift/right-drag pan · Scroll/pinch zoom · Double-click reset\n'
      'F R B L T views · 0 reset · W wireframe · G grid · Space spin',
      style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.55), height: 1.4),
    ),
  );
}

/// Saves what [key] wraps as a PNG at [path].
Future<void> saveShot(GlobalKey key, String path) async {
  final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final image = await boundary.toImage(pixelRatio: 2);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  File(path)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(png!.buffer.asUint8List());
}
