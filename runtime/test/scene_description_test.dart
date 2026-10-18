import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:img2flutterscene/img2flutterscene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// test/fixtures/sample_hard_case.scene.json is lab/specs/sample_hard_case.json
/// at its form-refinement pass; forge/tests/test_generate_flutter_scene.py
/// fails when it drifts from the generator.
SceneDescription _fixture() => SceneDescription.fromJson(
  jsonDecode(File('test/fixtures/sample_hard_case.scene.json').readAsStringSync()) as Map<String, Object?>,
);

void main() {
  test('parses the description, its omissions and materials', () {
    final s = _fixture();
    expect(s.target, 'TradeIt Hard Case');
    expect(s.factory, 'createTradeItHardCaseModel');
    expect(s.pass, 'form-refinement');
    expect(s.parts, hasLength(12));
    expect(s.omitted, contains('repetitionSystems (instancing is not ported yet)'));
    expect(s.materials['shellMatte']!.roughness, closeTo(0.62, 1e-9));
  });

  test('rejects anything that is not a scene description', () {
    expect(() => SceneDescription.fromJson({'format': 'something-else'}), throwsFormatException);
  });

  test('loads the pivot hierarchy the generated factory builds', () {
    final s = _fixture();
    final m = loadSceneDescription(s, buildMeshes: false);
    expect(m.nodes.keys, s.parts.map((p) => p.id));
    expect(m.nodes['root']!.parent, m.root);
    expect(m.nodes['padlock']!.parent, m.nodes['haspLoop']);
    expect(m.components['padlock']!.parent, 'haspLoop');
    final ridge = m.nodes['lidRidge']!;
    expect(ridge.position.y, closeTo(0.37, 1e-6));
    final want = eulerXyz(0, 0, 1.5708);
    expect(ridge.rotation.z, closeTo(want.z, 1e-6));
    expect(ridge.rotation.w, closeTo(want.w, 1e-6));
    // And the frame flip still wraps it.
    expect(m.root.globalTransform.determinant(), lessThan(0));
  });

  test('every op builds geometry sized by its baked scale', () {
    for (final part in _fixture().parts) {
      final b = buildPartGeometry(part);
      expect(b.vertexCount, greaterThan(0), reason: part.id);
      final box = b.bounds;
      final size = box.max - box.min;
      final s = part.scale;
      if (s == null || part.geometry['op'] != 'box') continue;
      for (var i = 0; i < 3; i++) {
        expect(size[i], closeTo(s[i], 1e-6), reason: '${part.id} axis $i');
      }
    }
  });

  test('an attachment frustum spans its endpoints and sits at the midpoint', () {
    final fastener = _fixture().parts.firstWhere((p) => p.id == 'lidFastener');
    expect(fastener.kind, 'attachment frustum');
    expect(fastener.scale, isNull);
    final b = buildPartGeometry(fastener);
    expect(b.bounds.max.y - b.bounds.min.y, closeTo(0.78, 1e-6));
    expect(fastener.meshPosition, vm.Vector3(0.39, 0, 0));
    expect(fastener.position, vm.Vector3(-0.39, 0, 0));
  });
}
