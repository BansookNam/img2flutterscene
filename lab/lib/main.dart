import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';
import 'package:img2flutterscene/img2flutterscene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'models/models.dart';

/// Reconstruction lab: one generated model, big, beside its reference image
/// — for matching the model to the reference and for the review gates'
/// screenshots.
///
/// Run: `flutter run -d macos` (from lab/), or `../scripts/lab_shot.sh`.
///   `--dart-define=MODEL=id`         start on a model (lib/models/models.dart)
///   `--dart-define=ANGLE=deg`        model yaw: 0 front, 90 its right side,
///                                    180 rear, 270 its left side
///   `--dart-define=ELEVATION=deg`    camera height above the model (default 12)
///   `--dart-define=BACKDROP=dark|mid|light`
///   `--dart-define=LAYOUT=model|side`  model alone (default for shots) or beside
///                                    the reference
///   `--dart-define=SHOT=name`        save `name_angle.png` for every angle in
///   `--dart-define=ANGLES=0,90,180,270`  (default: ANGLE) into the app's temp
///                                    dir, print `SHOT <path>` each, then quit
///
/// Hot reload (`r`) rebuilds the model, so regenerated factories show without
/// a restart. Space = spin/pause, ←/→ = nudge the angle, E = explode.
void main() => runApp(
  MaterialApp(debugShowCheckedModeBanner: false, theme: ThemeData.dark(useMaterial3: true), home: const _Lab()),
);

enum _Backdrop {
  dark('Dark', Color(0xFF14161C)),
  mid('Mid grey', Color(0xFF6B6F78)),
  light('Light', Color(0xFFF2EFE8));

  const _Backdrop(this.label, this.color);
  final String label;
  final Color color;
}

const _shot = String.fromEnvironment('SHOT');

class _Lab extends StatefulWidget {
  const _Lab();

  @override
  State<_Lab> createState() => _LabState();
}

class _LabState extends State<_Lab> {
  late String _id = () {
    const start = String.fromEnvironment('MODEL');
    return labModelById(start) != null ? start : labModels.first.id;
  }();
  bool _spin = false;
  bool _explode = false;
  double _yawDeg = double.parse(const String.fromEnvironment('ANGLE', defaultValue: '0'));
  final double _elevationDeg = double.parse(const String.fromEnvironment('ELEVATION', defaultValue: '12'));
  bool _sideBySide = const String.fromEnvironment('LAYOUT', defaultValue: _shot == '' ? 'side' : 'model') == 'side';
  _Backdrop _backdrop = _Backdrop.values.firstWhere(
    (b) => b.name == const String.fromEnvironment('BACKDROP', defaultValue: 'dark'),
    orElse: () => _Backdrop.dark,
  );
  final GlobalKey _shotKey = GlobalKey();

  /// Bumped on hot reload so the model view rebuilds its meshes.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (_shot.isNotEmpty) _shootAll(_shot);
  }

  @override
  void reassemble() {
    super.reassemble();
    _generation++;
  }

  Future<void> _shootAll(String name) async {
    const list = String.fromEnvironment('ANGLES');
    final angles = list.isEmpty ? [_yawDeg] : [for (final a in list.split(',')) double.parse(a.trim())];
    // Let the engine come up and auto-exposure settle before the first frame.
    await Future<void>.delayed(const Duration(seconds: 4));
    for (final a in angles) {
      setState(() => _yawDeg = a % 360);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await WidgetsBinding.instance.endOfFrame;
      final boundary = _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      // The app is sandboxed: write into its own temp dir and say where.
      final f = File('${Directory.systemTemp.path}/${name}_${a.round()}.png')
        ..writeAsBytesSync(png!.buffer.asUint8List());
      debugPrint('SHOT ${f.path}');
    }
    exit(0);
  }

  void _nudge(double deg) => setState(() {
    _spin = false;
    _yawDeg = (_yawDeg + deg) % 360;
  });

  @override
  Widget build(BuildContext context) {
    final model = labModelById(_id)!;
    final ref = model.reference;
    final view = _ModelView(
      key: ValueKey('$_id/$_generation'),
      model: model,
      yaw: _spin ? null : _yawDeg * vm.degrees2Radians,
      elevation: _elevationDeg * vm.degrees2Radians,
      explode: _explode,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.space): () => setState(() => _spin = !_spin),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _nudge(-15),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _nudge(15),
        const SingleActivator(LogicalKeyboardKey.keyE): () => setState(() => _explode = !_explode),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: _backdrop.color,
          body: SafeArea(
            child: Column(
              children: [
                if (_shot.isEmpty) _picker(),
                Expanded(
                  child: RepaintBoundary(
                    key: _shotKey,
                    child: ColoredBox(
                      color: _backdrop.color,
                      child: Row(
                        children: [
                          if (_sideBySide)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: _labelled(
                                  'Reference',
                                  ref == null
                                      ? const Center(child: Text('No reference image'))
                                      : Image.asset(ref, fit: BoxFit.contain),
                                ),
                              ),
                            ),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: _sideBySide ? _labelled('Model', view) : view,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (_shot.isEmpty) _controls(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _labelled(String label, Widget child) => Column(
    children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1.2)),
      const SizedBox(height: 6),
      Expanded(child: child),
    ],
  );

  Widget _picker() => Padding(
    padding: const EdgeInsets.all(12),
    child: Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        for (final m in labModels)
          ChoiceChip(label: Text(m.name), selected: m.id == _id, onSelected: (_) => setState(() => _id = m.id)),
      ],
    ),
  );

  Widget _controls() => Container(
    color: Colors.black54,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            SizedBox(width: 120, child: Text(_spin ? 'Spinning' : 'Angle ${_yawDeg.round()}°')),
            Expanded(
              child: Slider(
                max: 360,
                value: _yawDeg,
                onChanged: (v) => setState(() {
                  _spin = false;
                  _yawDeg = v;
                }),
              ),
            ),
          ],
        ),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            FilterChip(label: const Text('Spin'), selected: _spin, onSelected: (v) => setState(() => _spin = v)),
            FilterChip(
              label: const Text('Explode'),
              selected: _explode,
              onSelected: (v) => setState(() => _explode = v),
            ),
            FilterChip(
              label: const Text('Reference'),
              selected: _sideBySide,
              onSelected: (v) => setState(() => _sideBySide = v),
            ),
            for (final (label, deg) in const [('Front', 0.0), ('Right', 90.0), ('Rear', 180.0), ('Left', 270.0)])
              ActionChip(
                label: Text(label),
                onPressed: () => setState(() {
                  _spin = false;
                  _yawDeg = deg;
                }),
              ),
            for (final b in _Backdrop.values)
              ChoiceChip(
                label: Text(b.label),
                selected: b == _backdrop,
                onSelected: (_) => setState(() => _backdrop = b),
              ),
          ],
        ),
      ],
    ),
  );
}

/// One generated model on a turntable, framed to its bounds. The camera sits
/// on −Z — where flutter_scene shows the spec's front the way three.js does
/// from +Z (+X right, +Y up; see `threeJsFrame`) — and never moves; the model
/// turns, so yaw 90 shows the model's own right side (spec −X).
class _ModelView extends StatefulWidget {
  const _ModelView({super.key, required this.model, required this.yaw, required this.elevation, required this.explode});

  final LabModel model;
  final double? yaw;
  final double elevation;
  final bool explode;

  @override
  State<_ModelView> createState() => _ModelViewState();
}

class _ModelViewState extends State<_ModelView> {
  final Scene _scene = Scene();
  final Node _turntable = Node();
  final Node _centring = Node();
  SculptModel? _sculpt;
  double _radius = 1;
  double _spinAngle = 0;
  double _explodeAmount = 0;

  static const _fovY = 30 * vm.degrees2Radians;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await Scene.initializeStaticResources();
    final sculpt = widget.model.build();
    final bounds = sculpt.node.combinedLocalBounds;
    if (bounds != null) {
      _radius = math.max((bounds.max - bounds.min).length * 0.5, 1e-3);
      // Turn about the model's own centre, not the world origin.
      _centring.position = -(bounds.min + bounds.max) * 0.5;
    }
    _turntable.add(_centring..add(sculpt.node));
    _scene
      ..add(_turntable)
      ..directionalLight = DirectionalLight(
        direction: vm.Vector3(-0.35, -0.8, 0.5),
        intensity: 3.0,
        color: vm.Vector3(1, 0.97, 0.92),
      )
      ..environmentIntensity = 1.0
      ..environmentSettings = EnvironmentSettings(toneMapping: ToneMappingMode.aces);
    if (mounted) setState(() => _sculpt = sculpt);
  }

  void _tick(Duration elapsed, double dt) {
    _spinAngle += dt * 0.6;
    // −yaw: a positive angle brings the model's right side (spec −X, world
    // −X) round to the camera on −Z.
    _turntable.rotation = vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), -(widget.yaw ?? _spinAngle));
    final target = widget.explode ? _radius * 0.6 : 0.0;
    if ((target - _explodeAmount).abs() > 1e-4) {
      _explodeAmount += (target - _explodeAmount) * math.min(1, dt * 6);
      _sculpt!.explode(_explodeAmount);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_sculpt == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(
      builder: (context, box) {
        // Fit the bounding sphere in the tighter of the two fields of view:
        // a narrow panel (side-by-side layout) clips horizontally first.
        final aspect = box.maxWidth / math.max(box.maxHeight, 1);
        final fovX = 2 * math.atan(math.tan(_fovY / 2) * aspect);
        final distance = _radius / math.sin(math.min(_fovY, fovX) / 2) * 1.08;
        final e = widget.elevation;
        return SceneView(
          _scene,
          camera: PerspectiveCamera(
            position: vm.Vector3(0, math.sin(e), -math.cos(e)) * distance,
            target: vm.Vector3.zero(),
            fovRadiansY: _fovY,
          ),
          onTick: _tick,
        );
      },
    );
  }
}
