import 'dart:math' as math;

import 'package:flutter_scene/scene.dart';
import 'package:img2flutterscene/img2flutterscene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Every unit primitive the generator emits, side by side in a 5 × 2 grid —
/// not a reconstruction, a runtime check: a wrong normal or winding shows as
/// a black or inside-out part under the lab's light. Hand-written, so it
/// is not regenerated.
SculptModel createPrimitiveGalleryModel() {
  final material = PhysicallyBasedMaterial()..roughnessFactor = 0.45;
  final root = Node(name: 'Primitive gallery');
  final nodes = <String, Node>{};
  final components = <String, SculptComponent>{};
  final parts = <(String, void Function(PartBuilder b, vm.Vector4 c))>[
    ('box', (b, c) => b.unitBox(c)),
    ('sphere', (b, c) => b.unitSphere(c)),
    ('cylinder', (b, c) => b.unitCylinder(c)),
    ('cone', (b, c) => b.unitCone(c)),
    ('capsule', (b, c) => b.unitCapsule(c)),
    ('torus', (b, c) => b.unitTorus(c, tube: 0.12)),
    (
      'lathe',
      (b, c) =>
          b.latheY([vm.Vector2(0.3, -0.5), vm.Vector2(0.12, -0.1), vm.Vector2(0.18, 0.2), vm.Vector2(0.35, 0.5)], c),
    ),
    (
      'extrude',
      (b, c) => b.extrude(
        [
          for (var i = 0; i < 10; i++)
            vm.Vector2(math.cos(math.pi / 2 + i * math.pi / 5), math.sin(math.pi / 2 + i * math.pi / 5)) *
                (i.isEven ? 0.5 : 0.22),
        ],
        0.2,
        c,
      ),
    ),
    (
      'ellipsoid',
      (b, c) => b
        ..unitSphere(c)
        ..scale(vm.Vector3(1, 0.55, 0.7)),
    ),
    ('attachment', (b, c) => b.cylinder(vm.Vector3(0, -0.5, 0), vm.Vector3(0, 0.5, 0), 0.18, 0.1, c)),
  ];
  const hues = [
    0xFFD9534F,
    0xFFF0AD4E,
    0xFFE8D44D,
    0xFF5CB85C,
    0xFF3FB6A8,
    0xFF5BC0DE,
    0xFF428BCA,
    0xFF7E57C2,
    0xFFD65DB1,
    0xFFB0B4BC,
  ];
  for (var i = 0; i < parts.length; i++) {
    final (id, build) = parts[i];
    final pivot = Node(name: '${id}__pivot')
      ..position = vm.Vector3((i % 5 - 2) * 1.3, i < 5 ? 0.75 : -0.75, 0)
      // A slight turn so flat faces catch different light.
      ..rotation = eulerXyz(0.35, 0.5, 0);
    root.add(pivot);
    nodes[id] = pivot;
    components[id] = SculptComponent(id: id, name: id, role: 'sample');
    final b = PartBuilder();
    build(b, lin(hues[i]));
    pivot.add(Node(name: id, mesh: Mesh(b.build(), material)));
  }
  return SculptModel(root: root, nodes: nodes, components: components);
}
