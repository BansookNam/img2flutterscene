import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

import 'part_builder.dart';

/// The sculpt spec's primitives at the unit size the img2threejs generator
/// gives them, so one spec means the same shape on either target: box 1×1×1,
/// sphere ⌀1, cylinder and cone ⌀1 × 1 tall along Y, capsule r 0.35 with a
/// 0.7 straight section (1.4 tall), torus ring r 0.45 in the XY plane.
/// Everything is centred on the origin; the generator then bakes the part's
/// dimensions in with [PartBuilder.scale].
///
/// Built on PartBuilder's public calls only, so part_builder.dart stays a
/// straight copy of the one it came from.
extension UnitPrimitives on PartBuilder {
  /// Cube of side 1, flat-shaded faces, each split [seg]×[seg] so later
  /// deformations (taper, bend) have vertices to move.
  void unitBox(vm.Vector4 color, {int seg = 1}) {
    for (final (n, u, v) in [
      (vm.Vector3(1, 0, 0), vm.Vector3(0, 0, -1), vm.Vector3(0, 1, 0)),
      (vm.Vector3(-1, 0, 0), vm.Vector3(0, 0, 1), vm.Vector3(0, 1, 0)),
      (vm.Vector3(0, 1, 0), vm.Vector3(1, 0, 0), vm.Vector3(0, 0, -1)),
      (vm.Vector3(0, -1, 0), vm.Vector3(1, 0, 0), vm.Vector3(0, 0, 1)),
      (vm.Vector3(0, 0, 1), vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0)),
      (vm.Vector3(0, 0, -1), vm.Vector3(-1, 0, 0), vm.Vector3(0, 1, 0)),
    ]) {
      patch(
        [
          for (var j = 0; j <= seg; j++)
            [for (var i = 0; i <= seg; i++) n * 0.5 + u * (i / seg - 0.5) + v * (j / seg - 0.5)],
        ],
        (_, _) => n,
        (_, _) => color,
        uv: (j, i) => vm.Vector2(i / seg, j / seg),
      );
    }
  }

  /// Sphere of diameter 1 (an ellipsoid once scaled).
  void unitSphere(vm.Vector4 color, {int seg = 32, int rings = 16}) =>
      ellipsoid(vm.Vector3.zero(), vm.Vector3.all(0.5), color, seg: seg, rings: rings);

  void unitCylinder(vm.Vector4 color, {int seg = 32}) =>
      cylinder(vm.Vector3(0, -0.5, 0), vm.Vector3(0, 0.5, 0), 0.5, 0.5, color, seg: seg);

  /// Apex at +Y, like THREE.ConeGeometry.
  void unitCone(vm.Vector4 color, {int seg = 32}) =>
      cylinder(vm.Vector3(0, -0.5, 0), vm.Vector3(0, 0.5, 0), 0.5, 0, color, seg: seg);

  void unitCapsule(vm.Vector4 color, {int seg = 32, int capSeg = 8}) {
    const r = 0.35, half = 0.35;
    latheY(
      [
        for (var i = 0; i <= capSeg; i++)
          () {
            final a = -math.pi / 2 + math.pi / 2 * i / capSeg;
            return vm.Vector2(r * math.cos(a), -half + r * math.sin(a));
          }(),
        for (var i = 0; i <= capSeg; i++)
          () {
            final a = math.pi / 2 * i / capSeg;
            return vm.Vector2(r * math.cos(a), half + r * math.sin(a));
          }(),
      ],
      color,
      seg: seg,
    );
  }

  /// Ring of radius 0.45 around the Z axis; [tube] is the tube's radius.
  void unitTorus(vm.Vector4 color, {double tube = 0.08, int seg = 48, int tubeSeg = 16}) {
    const ring = 0.45;
    vm.Vector3 centre(int j) {
      final a = 2 * math.pi * j / seg;
      return vm.Vector3(math.cos(a), math.sin(a), 0);
    }

    vm.Vector3 normal(int j, int i) {
      final b = 2 * math.pi * i / tubeSeg;
      return centre(j) * math.cos(b) + vm.Vector3(0, 0, math.sin(b));
    }

    patch(
      [
        for (var j = 0; j <= seg; j++) [for (var i = 0; i <= tubeSeg; i++) centre(j) * ring + normal(j, i) * tube],
      ],
      normal,
      (_, _) => color,
      uv: (j, i) => vm.Vector2(j / seg, i / tubeSeg),
    );
  }

  /// A surface of revolution about the Y axis (THREE.LatheGeometry's axis):
  /// each [profile] point is (radius, y). Normals come from the profile's
  /// direction as in three — (dy, −dr) — so walk it bottom to top for an
  /// outward-facing solid. A radius of 0 closes a pole.
  void latheY(List<vm.Vector2> profile, vm.Vector4 color, {int seg = 32}) {
    final m = profile.length;
    final nrm = [
      for (var k = 0; k < m; k++)
        () {
          final t = profile[math.min(k + 1, m - 1)] - profile[math.max(k - 1, 0)];
          return vm.Vector2(t.y, -t.x)..normalize();
        }(),
    ];
    vm.Vector3 around(vm.Vector2 p, int i) {
      final a = 2 * math.pi * i / seg;
      return vm.Vector3(p.x * math.sin(a), p.y, p.x * math.cos(a));
    }

    patch(
      [
        for (var i = 0; i <= seg; i++) [for (final p in profile) around(vm.Vector2(math.max(p.x, 1e-4), p.y), i)],
      ],
      (i, k) => around(nrm[k], i)..normalize(),
      (_, _) => color,
      uv: (i, k) => vm.Vector2(i / seg, k / (m - 1)),
    );
  }

  /// The simple polygon [outline] (XY plane, either winding, no holes)
  /// extruded from z = 0 to z = [depth], like THREE.ExtrudeGeometry without
  /// bevels.
  void extrude(List<vm.Vector2> outline, double depth, vm.Vector4 color) {
    final old = xf;
    xf = old.clone()..translateByVector3(vm.Vector3(0, 0, depth / 2));
    slab(outline, earClip(outline), depth / 2, color, color);
    xf = old;
  }
}

/// Triangulates a simple polygon (no holes, no self-crossings) by ear
/// clipping; returns index triples into [poly].
List<int> earClip(List<vm.Vector2> poly) {
  var area = 0.0;
  for (var i = 0; i < poly.length; i++) {
    final a = poly[i], b = poly[(i + 1) % poly.length];
    area += a.x * b.y - b.x * a.y;
  }
  final ccw = area > 0;
  double cross(vm.Vector2 o, vm.Vector2 a, vm.Vector2 b) => (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  bool convex(vm.Vector2 a, vm.Vector2 b, vm.Vector2 c) => ccw ? cross(a, b, c) > 0 : cross(a, b, c) < 0;
  bool inside(vm.Vector2 p, vm.Vector2 a, vm.Vector2 b, vm.Vector2 c) {
    final d1 = cross(a, b, p), d2 = cross(b, c, p), d3 = cross(c, a, p);
    return !((d1 < 0 || d2 < 0 || d3 < 0) && (d1 > 0 || d2 > 0 || d3 > 0));
  }

  final left = [for (var i = 0; i < poly.length; i++) i];
  final out = <int>[];
  var guard = 0;
  while (left.length > 3 && guard++ < poly.length * poly.length) {
    for (var k = 0; k < left.length; k++) {
      final ia = left[(k - 1 + left.length) % left.length], ib = left[k], ic = left[(k + 1) % left.length];
      final a = poly[ia], b = poly[ib], c = poly[ic];
      if (!convex(a, b, c)) continue;
      if (left.any((j) => j != ia && j != ib && j != ic && inside(poly[j], a, b, c))) continue;
      out.addAll([ia, ib, ic]);
      left.removeAt(k);
      break;
    }
  }
  if (left.length != 3) throw ArgumentError('outline is not a simple polygon (${poly.length} points)');
  out.addAll(left);
  return out;
}
