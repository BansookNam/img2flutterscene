import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'part_builder.dart';
import 'sculpt_model.dart';
import 'unit_primitives.dart';

/// The scene-json version this loader reads (`SCENE_FORMAT` in
/// forge/stage3_build/generate_flutter_scene.py).
const sceneFormat = 'img2flutterscene.scene/1';

/// A model as data: what `generate_flutter_scene.py --format scene-json`
/// writes. It is rendered from the same description as the generated Dart
/// factory, so loading it gives the model that factory would build — without
/// compiling anything, which is what a running preview needs.
class SceneDescription {
  SceneDescription._({
    required this.target,
    required this.factory,
    required this.spec,
    required this.pass,
    required this.omitted,
    required this.unapplied,
    required this.materials,
    required this.parts,
  });

  factory SceneDescription.fromJson(Map<String, Object?> json) {
    final format = json['format'];
    if (format != sceneFormat) {
      throw FormatException('expected a $sceneFormat scene description, got format $format');
    }
    final materials = (json['materials'] as Map? ?? const {}).cast<String, Object?>();
    return SceneDescription._(
      target: json['target'] as String? ?? 'Object',
      factory: json['factory'] as String? ?? '',
      spec: json['spec'] as String? ?? '',
      pass: json['pass'] as String? ?? '',
      omitted: [for (final o in json['omitted'] as List? ?? const []) '$o'],
      unapplied: [for (final o in json['unapplied'] as List? ?? const []) '$o'],
      materials: {
        for (final MapEntry(:key, :value) in materials.entries)
          key: SceneMaterial(
            metallic: _double((value as Map)['metallic'], 0),
            roughness: _double(value['roughness'], 0.6),
          ),
      },
      parts: [for (final p in json['components'] as List? ?? const []) ScenePart._fromJson((p as Map).cast())],
    );
  }

  final String target;
  final String factory;
  final String spec;
  final String pass;

  /// Spec features the generator could not build at all (`--allow-partial`).
  final List<String> omitted;

  /// Refinements built without (the shape is approximate there).
  final List<String> unapplied;

  final Map<String, SceneMaterial> materials;
  final List<ScenePart> parts;
}

class SceneMaterial {
  const SceneMaterial({required this.metallic, required this.roughness});

  final double metallic;
  final double roughness;
}

/// One component: its pivot (position + Euler rotation, parent by id) and the
/// geometry op that builds its mesh.
class ScenePart {
  ScenePart._fromJson(Map<String, Object?> j)
    : id = j['id'] as String,
      name = j['name'] as String? ?? j['id'] as String,
      role = j['role'] as String? ?? '',
      parent = j['parent'] as String?,
      kind = j['kind'] as String? ?? '',
      position = _vec3(j['position']),
      rotation = _vec3(j['rotation']),
      material = j['material'] as String?,
      color = int.parse((j['color'] as String).replaceFirst('0x', ''), radix: 16),
      geometry = (j['geometry'] as Map).cast<String, Object?>(),
      scale = j['scale'] == null ? null : _vec3(j['scale']),
      meshPosition = j['meshPosition'] == null ? null : _vec3(j['meshPosition']),
      meshRotation = j['meshRotation'] == null ? null : _quat(j['meshRotation']);

  final String id;
  final String name;
  final String role;
  final String? parent;

  /// The spec primitive, or "attachment frustum" for an endpoint part.
  final String kind;
  final vm.Vector3 position;

  /// Euler XYZ radians, as [eulerXyz] takes them.
  final vm.Vector3 rotation;
  final String? material;

  /// 0xAARRGGBB, sRGB.
  final int color;
  final Map<String, Object?> geometry;

  /// Dimensions baked into the vertices; null for an attachment frustum.
  final vm.Vector3? scale;

  /// Mesh placement inside the pivot (attachment frustums only).
  final vm.Vector3? meshPosition;
  final vm.Quaternion? meshRotation;
}

/// Builds [part]'s geometry exactly as the generated factory does: the op's
/// PartBuilder call, then the baked scale.
PartBuilder buildPartGeometry(ScenePart part) {
  final g = part.geometry;
  final color = lin(part.color);
  int i(String k) => (g[k] as num).toInt();
  double d(String k) => (g[k] as num).toDouble();
  List<vm.Vector2> pts() => [
    for (final p in g['points'] as List) vm.Vector2((p as List)[0].toDouble(), p[1].toDouble()),
  ];
  final b = PartBuilder();
  switch (g['op']) {
    case 'box':
      b.unitBox(color, seg: i('seg'));
    case 'sphere':
      b.unitSphere(color, seg: i('seg'), rings: i('rings'));
    case 'cylinder':
      b.unitCylinder(color, seg: i('seg'));
    case 'cone':
      b.unitCone(color, seg: i('seg'));
    case 'capsule':
      b.unitCapsule(color, seg: i('seg'), capSeg: i('capSeg'));
    case 'torus':
      b.unitTorus(color, tube: d('tube'), seg: i('seg'), tubeSeg: i('tubeSeg'));
    case 'lathe':
      b.latheY(pts(), color, seg: i('seg'));
    case 'extrude':
      b.extrude(pts(), d('depth'), color);
    case 'frustum':
      final h = d('halfLength');
      b.cylinder(vm.Vector3(0, -h, 0), vm.Vector3(0, h, 0), d('baseRadius'), d('endRadius'), color, seg: i('seg'));
    case final op:
      throw FormatException('unknown geometry op $op in part ${part.id}');
  }
  final s = part.scale;
  if (s != null) b.scale(s);
  return b;
}

/// Builds [scene] into a [SculptModel] — the same node tree, names and
/// materials the generated factory makes. [buildMeshes] false gives the bare
/// pivot hierarchy (no GPU needed — for tests and structure checks).
SculptModel loadSceneDescription(SceneDescription scene, {bool buildMeshes = true}) {
  final materials = buildMeshes
      ? {
          for (final MapEntry(:key, :value) in scene.materials.entries)
            key: PhysicallyBasedMaterial()
              ..metallicFactor = value.metallic
              ..roughnessFactor = value.roughness,
        }
      : const <String, PhysicallyBasedMaterial>{};
  PhysicallyBasedMaterial? fallback;
  final root = Node(name: scene.target);
  final nodes = <String, Node>{};
  final components = <String, SculptComponent>{};
  for (final part in scene.parts) {
    final pivot = Node(name: '${part.name}__pivot')
      ..position = part.position
      ..rotation = eulerXyz(part.rotation.x, part.rotation.y, part.rotation.z);
    (part.parent == null ? root : nodes[part.parent]!).add(pivot);
    nodes[part.id] = pivot;
    components[part.id] = SculptComponent(id: part.id, name: part.name, role: part.role, parent: part.parent);
    if (!buildMeshes) continue;
    final material = materials[part.material] ?? (fallback ??= PhysicallyBasedMaterial()..roughnessFactor = 0.6);
    final mesh = Node(name: part.name, mesh: Mesh(buildPartGeometry(part).build(), material));
    if (part.meshPosition != null) mesh.position = part.meshPosition!;
    if (part.meshRotation != null) mesh.rotation = part.meshRotation!;
    pivot.add(mesh);
  }
  return SculptModel(root: root, nodes: nodes, components: components);
}

double _double(Object? v, double fallback) => v is num ? v.toDouble() : fallback;

vm.Vector3 _vec3(Object? v) {
  final l = v as List;
  return vm.Vector3((l[0] as num).toDouble(), (l[1] as num).toDouble(), (l[2] as num).toDouble());
}

vm.Quaternion _quat(Object? v) {
  final l = v as List;
  return vm.Quaternion(
    (l[0] as num).toDouble(),
    (l[1] as num).toDouble(),
    (l[2] as num).toDouble(),
    (l[3] as num).toDouble(),
  );
}
