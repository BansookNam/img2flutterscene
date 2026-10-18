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

  test('explode pushes top-level parts along their rest offset and back', () {
    final m = model();
    m.explode(1);
    final p = m.nodes['part']!.position;
    final rest = vm.Vector3(1, 2, 3);
    expect((p - rest).length, closeTo(1, 1e-6));
    expect((p - rest).normalized().dot(rest.normalized()), closeTo(1, 1e-6));
    m.explode(0);
    expect((m.nodes['part']!.position - rest).length, closeTo(0, 1e-6));
  });
}
