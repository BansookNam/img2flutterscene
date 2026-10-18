import 'package:flutter_scene/scene.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:img2flutterscene/img2flutterscene.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  SculptModel model() {
    final root = Node(name: 'm');
    final part = Node(name: 'part')..position = vm.Vector3(1, 2, 3);
    root.add(part);
    return SculptModel(
      root: root,
      nodes: {'part': part},
      components: {'part': const SculptComponent(id: 'part', name: 'part', role: 'body')},
    );
  }

  test('node maps the spec frame into flutter_scene by mirroring Z', () {
    final m = model();
    final world = m.nodes['part']!.globalTransform.transform3(vm.Vector3.zero());
    expect(world.x, closeTo(1, 1e-6));
    expect(world.y, closeTo(2, 1e-6));
    expect(world.z, closeTo(-3, 1e-6));
    // A reflection, so the engine flips winding under it.
    expect(m.root.globalTransform.determinant(), lessThan(0));
  });

  test('moving the model leaves the frame intact', () {
    final m = model();
    m.node.position = vm.Vector3(10, 0, 0);
    final world = m.nodes['part']!.globalTransform.transform3(vm.Vector3.zero());
    expect(world.x, closeTo(11, 1e-6));
    expect(world.z, closeTo(-3, 1e-6));
  });

  test('explode pushes parts along their rest offset and back', () {
    final m = model();
    m.explode(1);
    final p = m.nodes['part']!.position;
    final rest = vm.Vector3(1, 2, 3);
    expect((p - rest).length, closeTo(1, 1e-6));
    expect((p - rest).normalized().dot(rest.normalized()), closeTo(1, 1e-6));
    m.explode(0);
    expect((m.nodes['part']!.position - rest).length, closeTo(0, 1e-6));
  });

  test('explode reaches nested parts, which carry their parents along', () {
    final root = Node(name: 'm');
    final body = Node(name: 'body');
    final lid = Node(name: 'lid')..position = vm.Vector3(0, 1, 0);
    final hinge = Node(name: 'hinge');
    root.add(body);
    body.add(lid);
    lid.add(hinge);
    final m = SculptModel(
      root: root,
      nodes: {'body': body, 'lid': lid, 'hinge': hinge},
      components: {
        'body': const SculptComponent(id: 'body', name: 'body', role: 'body'),
        'lid': const SculptComponent(id: 'lid', name: 'lid', role: 'lid', parent: 'body'),
        'hinge': const SculptComponent(id: 'hinge', name: 'hinge', role: 'hinge', parent: 'lid'),
      },
    );
    m.explode(0.5);
    expect(lid.position.y, closeTo(1.5, 1e-6), reason: 'a child of the only top-level part still moves');
    expect(body.position.length, 0, reason: 'a part at its parent origin has no direction to move in');
    expect(hinge.position.length, 0);
  });
}
