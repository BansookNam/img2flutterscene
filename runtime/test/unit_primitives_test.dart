import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:img2flutterscene/img2flutterscene.dart';
import 'package:vector_math/vector_math.dart' as vm;

final _white = vm.Vector4(1, 1, 1, 1);

void _expectBounds(PartBuilder b, vm.Vector3 lo, vm.Vector3 hi, {double tol = 1e-6}) {
  final box = b.bounds;
  for (var i = 0; i < 3; i++) {
    expect(box.min[i], closeTo(lo[i], tol), reason: 'min[$i]');
    expect(box.max[i], closeTo(hi[i], tol), reason: 'max[$i]');
  }
}

void main() {
  group('unit sizes match the three.js generator', () {
    test('box is 1×1×1', () {
      _expectBounds(PartBuilder()..unitBox(_white), vm.Vector3.all(-0.5), vm.Vector3.all(0.5));
    });

    test('sphere has diameter 1', () {
      _expectBounds(PartBuilder()..unitSphere(_white), vm.Vector3.all(-0.5), vm.Vector3.all(0.5));
    });

    test('cylinder and cone are ⌀1 × 1 along Y', () {
      for (final b in [PartBuilder()..unitCylinder(_white), PartBuilder()..unitCone(_white)]) {
        _expectBounds(b, vm.Vector3(-0.5, -0.5, -0.5), vm.Vector3(0.5, 0.5, 0.5));
      }
    });

    test('capsule is r 0.35 and 1.4 tall', () {
      _expectBounds(
        PartBuilder()..unitCapsule(_white),
        vm.Vector3(-0.35, -0.7, -0.35),
        vm.Vector3(0.35, 0.7, 0.35),
        tol: 1e-3,
      );
    });

    test('torus ring 0.45 lies in the XY plane', () {
      _expectBounds(
        PartBuilder()..unitTorus(_white, tube: 0.1),
        vm.Vector3(-0.55, -0.55, -0.1),
        vm.Vector3(0.55, 0.55, 0.1),
        tol: 1e-3,
      );
    });

    test('extrude runs from z 0 to depth', () {
      final b = PartBuilder()
        ..extrude(
          [vm.Vector2(-0.3, -0.3), vm.Vector2(0.3, -0.3), vm.Vector2(0.3, 0.3), vm.Vector2(-0.3, 0.3)],
          0.1,
          _white,
        );
      _expectBounds(b, vm.Vector3(-0.3, -0.3, 0), vm.Vector3(0.3, 0.3, 0.1));
    });
  });

  test('scale bakes dimensions into the vertices', () {
    final b = PartBuilder()
      ..unitBox(_white)
      ..scale(vm.Vector3(1, 0.46, 0.78));
    _expectBounds(b, vm.Vector3(-0.5, -0.23, -0.39), vm.Vector3(0.5, 0.23, 0.39));
  });

  test('earClip triangulates a concave outline into n − 2 triangles', () {
    // An L shape: one reflex corner.
    final l = [
      vm.Vector2(0, 0),
      vm.Vector2(2, 0),
      vm.Vector2(2, 1),
      vm.Vector2(1, 1),
      vm.Vector2(1, 2),
      vm.Vector2(0, 2),
    ];
    for (final poly in [l, l.reversed.toList()]) {
      final tris = earClip(poly);
      expect(tris.length, (poly.length - 2) * 3);
      var area = 0.0;
      for (var t = 0; t < tris.length; t += 3) {
        final a = poly[tris[t]], b = poly[tris[t + 1]], c = poly[tris[t + 2]];
        area += ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)).abs() / 2;
      }
      expect(area, closeTo(3, 1e-9), reason: 'triangles must tile the L exactly');
    }
  });

  test('eulerXyz is three.js "XYZ" order (R = Rx·Ry·Rz)', () {
    // vector_math (not _64) stores float32: compare to ~1e-6.
    const x = 0.3, y = -0.7, z = 1.1;
    final expected = vm.Matrix3.rotationX(x) * vm.Matrix3.rotationY(y) * vm.Matrix3.rotationZ(z) as vm.Matrix3;
    final got = eulerXyz(x, y, z).asRotationMatrix();
    for (var i = 0; i < 9; i++) {
      expect(got.storage[i], closeTo(expected.storage[i], 1e-6));
    }
    // A quarter turn about Z alone takes +X to +Y — checked through
    // Matrix4.compose, which is what a Node's rotation feeds the renderer.
    // (vm.Quaternion.rotated applies the conjugate: never judge an
    // orientation with it.)
    final m = vm.Matrix4.compose(vm.Vector3.zero(), eulerXyz(0, 0, math.pi / 2), vm.Vector3.all(1));
    expect(m.transform3(vm.Vector3(1, 0, 0)).y, closeTo(1, 1e-6));
  });
}
