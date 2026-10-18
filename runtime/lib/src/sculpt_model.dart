import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Rotation from the spec's Euler angles (radians, three's default "XYZ"
/// order: R = Rx · Ry · Rz), so a transform reads the same on both targets.
vm.Quaternion eulerXyz(double x, double y, double z) =>
    vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), x) *
    vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), y) *
    vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), z);

/// What the spec says about one component, kept beside its node so a game
/// can pick, explode or animate parts by their spec id and role.
class SculptComponent {
  const SculptComponent({required this.id, required this.name, required this.role, this.parent});

  final String id;
  final String name;
  final String role;
  final String? parent;
}

/// Maps the spec's frame (three.js: right-handed, +Y up, front +Z) into
/// flutter_scene's, which is mirrored through Z relative to it — the same
/// flip flutter_scene's own glTF importer puts on an imported root. The
/// engine flips triangle winding under a negative-determinant transform, so
/// meshes stay lit from the right side.
vm.Matrix4 threeJsFrame() => vm.Matrix4.diagonal3Values(1, 1, -1);

/// A generated model: [root] holds one pivot node per spec component, found
/// by id in [nodes]. A pivot carries only position and rotation (scale stays
/// 1, sizes are baked into the mesh under it), so rotating a pivot turns its
/// part — and every part parented to it — about the part's own joint.
///
/// Add [node] to a scene, not [root]: [root] lives in the spec's frame, and
/// [node] wraps it in [threeJsFrame] so a spec's left stays on the left.
/// Move, turn or scale [node]; never replace the frame node's transform, or
/// the model renders mirrored.
class SculptModel {
  SculptModel({required this.root, required this.nodes, required this.components})
    : node = Node(name: root.name),
      _rest = {for (final e in nodes.entries) e.key: e.value.position} {
    // Built eagerly: until [root] sits under the frame, its transforms read
    // unmirrored.
    node.add(Node(name: '${root.name} (three.js frame)', localTransform: threeJsFrame())..add(root));
  }

  /// Spec-frame root: positions and rotations here read exactly as the spec
  /// (and the three.js target) states them.
  final Node root;

  /// The node to place in a scene; seen from −Z (+X right, +Y up) it shows
  /// the spec's front the way three.js shows it from +Z.
  final Node node;

  final Map<String, Node> nodes;
  final Map<String, SculptComponent> components;
  final Map<String, vm.Vector3> _rest;

  /// Pushes every top-level part away from the model's centre by [amount]
  /// along its rest offset (0 = assembled) — the "explodable" contract.
  void explode(double amount) {
    for (final MapEntry(key: id, value: node) in nodes.entries) {
      final rest = _rest[id]!;
      if (components[id]?.parent != null || rest.length2 < 1e-12) continue;
      node.position = rest + rest.normalized() * amount;
    }
  }
}
