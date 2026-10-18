import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// sRGB 0xAARRGGBB → linear-space Vector4 (the engine's factor space).
vm.Vector4 lin(int argb, {double a = 1, double gain = 1}) {
  double ch(int shift) {
    final c = ((argb >> shift) & 0xFF) / 255.0;
    return (c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble()) * gain;
  }

  return vm.Vector4(ch(16), ch(8), ch(0), a);
}

/// Accumulates vertex-coloured parts into ONE [MeshGeometry], so a whole
/// multi-colour prop (an apple with stem + leaf, a faceted gem, a snake face)
/// is a single draw — and, under an [InstancedMesh], a single draw for every
/// copy on the field.
///
/// Every triangle is auto-wound: its geometric normal is compared with the
/// vertex normals and flipped if it faces inward, so callers never have to
/// think about winding (the engine wants CCW-from-outside).
class PartBuilder {
  final List<double> _pos = [];
  final List<double> _nrm = [];
  final List<double> _uv = [];
  final List<double> _col = [];
  final List<int> _idx = [];

  /// Applied to every part added (rotation + translation only).
  vm.Matrix4 xf = vm.Matrix4.identity();

  /// When set, every vertex added gets this uv0 instead of its own — a
  /// per-part tag a custom material can branch on (water marks its surface
  /// vs its walls this way).
  vm.Vector2? uvTag;

  int get vertexCount => _pos.length ~/ 3;

  int _v(vm.Vector3 p, vm.Vector3 n, vm.Vector4 c, [double u = 0, double v = 0]) {
    final tp = xf.transformed3(p);
    final tn = xf.rotated3(n)..normalize();
    _pos.addAll([tp.x, tp.y, tp.z]);
    _nrm.addAll([tn.x, tn.y, tn.z]);
    final tag = uvTag;
    _uv.addAll(tag == null ? [u, v] : [tag.x, tag.y]);
    _col.addAll([c.x, c.y, c.z, c.w]);
    return vertexCount - 1;
  }

  vm.Vector3 _p(int i) => vm.Vector3(_pos[i * 3], _pos[i * 3 + 1], _pos[i * 3 + 2]);
  vm.Vector3 _n(int i) => vm.Vector3(_nrm[i * 3], _nrm[i * 3 + 1], _nrm[i * 3 + 2]);

  void _tri(int a, int b, int c) {
    final pa = _p(a), pb = _p(b), pc = _p(c);
    final g = (pb - pa).cross(pc - pa);
    if (g.length2 < 1e-14) return;
    final avg = _n(a) + _n(b) + _n(c);
    if (g.dot(avg) < 0) {
      _idx.addAll([a, c, b]);
    } else {
      _idx.addAll([a, b, c]);
    }
  }

  /// Smooth-shaded ellipsoid centred at [c] with semi-axes [r].
  /// [yMin] (−1..1) clips the bottom (e.g. 0 = a dome).
  void ellipsoid(vm.Vector3 c, vm.Vector3 r, vm.Vector4 color, {int seg = 16, int rings = 10, double yMin = -1}) {
    final base = vertexCount;
    final latMin = math.asin(yMin.clamp(-1.0, 1.0));
    for (var j = 0; j <= rings; j++) {
      final lat = latMin + (math.pi / 2 - latMin) * j / rings;
      final cy = math.sin(lat), cr = math.cos(lat);
      for (var i = 0; i <= seg; i++) {
        final lon = 2 * math.pi * i / seg;
        final u = vm.Vector3(cr * math.cos(lon), cy, cr * math.sin(lon));
        final p = vm.Vector3(c.x + u.x * r.x, c.y + u.y * r.y, c.z + u.z * r.z);
        final n = vm.Vector3(u.x / r.x, u.y / r.y, u.z / r.z)..normalize();
        _v(p, n, color, i / seg, j / rings);
      }
    }
    for (var j = 0; j < rings; j++) {
      for (var i = 0; i < seg; i++) {
        final a = base + j * (seg + 1) + i;
        final b = a + seg + 1;
        _tri(a, b, a + 1);
        _tri(a + 1, b, b + 1);
      }
    }
    if (yMin > -1) {
      // Flat cap over the clipped bottom.
      final cy = c.y + yMin * r.y;
      final rr = math.sqrt(1 - yMin * yMin);
      final down = vm.Vector3(0, -1, 0);
      final mid = _v(vm.Vector3(c.x, cy, c.z), down, color);
      final ring = <int>[
        for (var i = 0; i <= seg; i++)
          _v(
            vm.Vector3(
              c.x + math.cos(2 * math.pi * i / seg) * rr * r.x,
              cy,
              c.z + math.sin(2 * math.pi * i / seg) * rr * r.z,
            ),
            down,
            color,
          ),
      ];
      for (var i = 0; i < seg; i++) {
        _tri(mid, ring[i], ring[i + 1]);
      }
    }
  }

  void sphere(vm.Vector3 c, double r, vm.Vector4 color, {int seg = 12, int rings = 8}) =>
      ellipsoid(c, vm.Vector3.all(r), color, seg: seg, rings: rings);

  /// Smooth-sided (optionally capped) frustum from [a] (radius [ra]) to [b]
  /// (radius [rb]). rb = 0 makes a cone.
  void cylinder(vm.Vector3 a, vm.Vector3 b, double ra, double rb, vm.Vector4 color, {int seg = 12, bool caps = true}) {
    final axis = b - a;
    final len = axis.length;
    final dir = axis / len;
    final helper = dir.y.abs() > 0.9 ? vm.Vector3(1, 0, 0) : vm.Vector3(0, 1, 0);
    final ux = helper.cross(dir)..normalize();
    final uy = dir.cross(ux)..normalize();
    final slope = (ra - rb) / len;
    final base = vertexCount;
    for (var i = 0; i <= seg; i++) {
      final t = 2 * math.pi * i / seg;
      final radial = ux * math.cos(t) + uy * math.sin(t);
      final n = (radial + dir * slope)..normalize();
      _v(a + radial * ra, n, color);
      _v(b + radial * rb, n, color);
    }
    for (var i = 0; i < seg; i++) {
      final k = base + i * 2;
      _tri(k, k + 1, k + 2);
      _tri(k + 2, k + 1, k + 3);
    }
    if (!caps) return;
    for (final (centre, r, n) in [(a, ra, -dir), (b, rb, dir)]) {
      if (r <= 0) continue;
      final m = _v(centre, n, color);
      final ring = <int>[
        for (var i = 0; i <= seg; i++)
          _v(centre + (ux * math.cos(2 * math.pi * i / seg) + uy * math.sin(2 * math.pi * i / seg)) * r, n, color),
      ];
      for (var i = 0; i < seg; i++) {
        _tri(m, ring[i], ring[i + 1]);
      }
    }
  }

  /// A flat-shaded triangle (its own three vertices); [out] is any point on
  /// the outside of the face, used only to orient it.
  void facet(vm.Vector3 a, vm.Vector3 b, vm.Vector3 c, vm.Vector4 color, vm.Vector3 out) {
    var n = (b - a).cross(c - a)..normalize();
    final centroid = (a + b + c) / 3;
    if (n.dot(out - centroid) < 0) n = -n;
    final i0 = _v(a, n, color), i1 = _v(b, n, color), i2 = _v(c, n, color);
    _tri(i0, i1, i2);
  }

  /// A flat-shaded slab: the 2D polygon [poly] (in the XY plane, triangulated
  /// by [tris]) extruded ±[halfDepth] along Z, with flat side walls.
  void slab(List<vm.Vector2> poly, List<int> tris, double halfDepth, vm.Vector4 face, vm.Vector4 side) {
    for (final z in [halfDepth, -halfDepth]) {
      final n = vm.Vector3(0, 0, z.sign);
      final idx = [for (final p in poly) _v(vm.Vector3(p.x, p.y, z), n, face)];
      for (var t = 0; t < tris.length; t += 3) {
        _tri(idx[tris[t]], idx[tris[t + 1]], idx[tris[t + 2]]);
      }
    }
    // Side walls: outward = away from the polygon's centroid along the edge normal.
    var area = 0.0;
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      area += a.x * b.y - b.x * a.y;
    }
    final ccw = area > 0;
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      final e = b - a;
      final en = ccw ? vm.Vector2(e.y, -e.x) : vm.Vector2(-e.y, e.x);
      en.normalize();
      final n = vm.Vector3(en.x, en.y, 0);
      final i0 = _v(vm.Vector3(a.x, a.y, halfDepth), n, side);
      final i1 = _v(vm.Vector3(b.x, b.y, halfDepth), n, side);
      final i2 = _v(vm.Vector3(b.x, b.y, -halfDepth), n, side);
      final i3 = _v(vm.Vector3(a.x, a.y, -halfDepth), n, side);
      _tri(i0, i1, i2);
      _tri(i0, i2, i3);
    }
  }

  /// A surface of revolution about the Z axis. Each [profile] sample is a
  /// point (radius, z), its outward normal in that (r, z) plane, and a
  /// colour. Repeat a point with a different normal for a hard crease — the
  /// zero-width strip between the two copies is dropped as degenerate.
  void lathe(List<(double r, double z, double nr, double nz, vm.Vector4 color)> profile, {int seg = 48}) {
    final base = vertexCount;
    for (final (r, z, nr, nz, color) in profile) {
      final nl = math.sqrt(nr * nr + nz * nz);
      for (var i = 0; i <= seg; i++) {
        final a = 2 * math.pi * i / seg;
        final c = math.cos(a), s = math.sin(a);
        _v(vm.Vector3(r * c, r * s, z), vm.Vector3(nr / nl * c, nr / nl * s, nz / nl), color);
      }
    }
    for (var j = 0; j < profile.length - 1; j++) {
      for (var i = 0; i < seg; i++) {
        final a = base + j * (seg + 1) + i;
        final b = a + seg + 1;
        _tri(a, b, a + 1);
        _tri(a + 1, b, b + 1);
      }
    }
  }

  /// A rounded bead of half-width [w] and height [h] swept along the 2D
  /// [path] in the local XY plane, domed toward +Z with its flat base on
  /// z = 0 — embossed lettering on a face. Joints and ends get matching
  /// half-buried domes so corners stay round.
  void ridge(List<vm.Vector2> path, double w, double h, vm.Vector4 color, {int seg = 10}) {
    final base = vertexCount;
    for (var k = 0; k < path.length; k++) {
      final prev = path[math.max(k - 1, 0)];
      final next = path[math.min(k + 1, path.length - 1)];
      final t = (next - prev)..normalize();
      final side = vm.Vector3(t.y, -t.x, 0);
      final c = vm.Vector3(path[k].x, path[k].y, 0);
      for (var i = 0; i <= seg; i++) {
        final phi = math.pi * i / seg;
        final cs = math.cos(phi), sn = math.sin(phi);
        _v(
          c + side * (w * cs) + vm.Vector3(0, 0, h * sn),
          (side * (cs / w) + vm.Vector3(0, 0, sn / h))..normalize(),
          color,
        );
      }
    }
    for (var k = 0; k < path.length - 1; k++) {
      for (var i = 0; i < seg; i++) {
        final a = base + k * (seg + 1) + i;
        final b = a + seg + 1;
        _tri(a, b, a + 1);
        _tri(a + 1, b, b + 1);
      }
    }
    for (final p in [path.first, path.last]) {
      ellipsoid(vm.Vector3(p.x, p.y, 0), vm.Vector3(w, w, h), color, seg: seg * 2, rings: seg);
    }
  }

  /// A square-shouldered bar of half-width [w] and height [h] swept along
  /// the 2D [path] in the local XY plane, flat base on z = 0, top toward +Z —
  /// the chunky, angular cousin of [ridge]. Its top edges are rounded by
  /// [round]; every bend in [path] is a mitred, hard-creased corner and the
  /// ends are cut flat, so a polyline reads as crisp blocky lettering.
  /// With [smooth], the walls shade continuously through each bend instead,
  /// so a finely sampled curve reads as one rounded stroke.
  void bar(
    List<vm.Vector2> path,
    double w,
    double h,
    vm.Vector4 color, {
    double round = 0.02,
    int roundSeg = 4,
    bool smooth = false,
  }) {
    // Cross-section (side offset s, height z) with its normal (ns, nz):
    // straight walls, flat top, quarter-round shoulders.
    final r = math.min(round, math.min(w, h) * 0.9);
    final prof = <(double, double, double, double)>[
      (-w, 0, -1, 0),
      (-w, h - r, -1, 0),
      for (var i = 1; i < roundSeg; i++)
        () {
          final a = math.pi - math.pi / 2 * i / roundSeg;
          final c = math.cos(a), s = math.sin(a);
          return (-w + r + r * c, h - r + r * s, c, s);
        }(),
      (-w + r, h, 0, 1),
      (w - r, h, 0, 1),
      for (var i = 1; i < roundSeg; i++)
        () {
          final a = math.pi / 2 - math.pi / 2 * i / roundSeg;
          final c = math.cos(a), s = math.sin(a);
          return (w - r + r * c, h - r + r * s, c, s);
        }(),
      (w, h - r, 1, 0),
      (w, 0, 1, 0),
    ];

    vm.Vector2 perp(vm.Vector2 t) => vm.Vector2(t.y, -t.x);
    final n = path.length;
    final segSide = [for (var k = 0; k < n - 1; k++) perp((path[k + 1] - path[k])..normalize())];
    // Mitre offset at each vertex: m·side == 1 for both adjoining segments.
    final mitre = [
      for (var k = 0; k < n; k++)
        () {
          final a = segSide[math.max(k - 1, 0)];
          final b = segSide[math.min(k, n - 2)];
          return (a + b) / (1 + a.dot(b));
        }(),
    ];

    for (var k = 0; k < n - 1; k++) {
      final base = vertexCount;
      for (final j in [k, k + 1]) {
        final c = vm.Vector3(path[j].x, path[j].y, 0);
        final m = vm.Vector3(mitre[j].x, mitre[j].y, 0);
        final side = smooth ? m.normalized() : vm.Vector3(segSide[k].x, segSide[k].y, 0);
        for (final (s, z, ns, nz) in prof) {
          _v(c + m * s + vm.Vector3(0, 0, z), (side * ns + vm.Vector3(0, 0, nz))..normalize(), color);
        }
      }
      final p = prof.length;
      for (var i = 0; i < p - 1; i++) {
        _tri(base + i, base + p + i, base + i + 1);
        _tri(base + i + 1, base + p + i, base + p + i + 1);
      }
    }

    // Flat end caps, facing back/forward along the path.
    for (final (j, other) in [(0, 1), (n - 1, n - 2)]) {
      final t = (path[j] - path[other])..normalize();
      final out = vm.Vector3(t.x, t.y, 0);
      final c = vm.Vector3(path[j].x, path[j].y, 0);
      final m = vm.Vector3(mitre[j].x, mitre[j].y, 0);
      final mid = _v(c + vm.Vector3(0, 0, h * 0.5), out, color);
      final ring = [for (final (s, z, _, _) in prof) _v(c + m * s + vm.Vector3(0, 0, z), out, color)];
      for (var i = 0; i < ring.length; i++) {
        _tri(mid, ring[i], ring[(i + 1) % ring.length]);
      }
    }
  }

  /// A smooth skin through closed [rings] (each the same number of points,
  /// walked in the same direction), coloured per (ring, point) by [color].
  /// Normals are central differences along and across the rings, flipped to agree with
  /// [outward] — so call it once per smoothing group, and repeat the shared
  /// ring in the next call for a hard crease between groups.
  void loft(
    List<List<vm.Vector3>> rings,
    vm.Vector4 Function(int ring, int i) color,
    vm.Vector3 Function(vm.Vector3 p) outward,
  ) {
    final m = rings.first.length;
    final base = vertexCount;
    for (var j = 0; j < rings.length; j++) {
      final r = rings[j];
      final lo = rings[math.max(j - 1, 0)];
      final hi = rings[math.min(j + 1, rings.length - 1)];
      for (var i = 0; i < m; i++) {
        final along = r[(i + 1) % m] - r[(i - 1 + m) % m];
        final across = hi[i] - lo[i];
        var n = across.cross(along)..normalize();
        if (n.dot(outward(r[i])) < 0) n = -n;
        _v(r[i], n, color(j, i));
      }
    }
    for (var j = 0; j < rings.length - 1; j++) {
      for (var i = 0; i < m; i++) {
        final a = base + j * m + i, b = base + j * m + (i + 1) % m;
        _tri(a, a + m, b);
        _tri(b, a + m, b + m);
      }
    }
  }

  /// An open grid through [rows] (each the same length), every vertex given
  /// its own [normal] and [color] — a curved facet that shades smoothly
  /// inside but keeps hard edges against its neighbours. Rows may collapse
  /// to a point (an apex); the degenerate triangles are dropped.
  void patch(
    List<List<vm.Vector3>> rows,
    vm.Vector3 Function(int row, int i) normal,
    vm.Vector4 Function(int row, int i) color, {
    vm.Vector2 Function(int row, int i)? uv,
  }) {
    final m = rows.first.length;
    final base = vertexCount;
    for (var j = 0; j < rows.length; j++) {
      for (var i = 0; i < m; i++) {
        final t = uv?.call(j, i);
        _v(rows[j][i], normal(j, i), color(j, i), t?.x ?? 0, t?.y ?? 0);
      }
    }
    for (var j = 0; j < rows.length - 1; j++) {
      for (var i = 0; i < m - 1; i++) {
        final a = base + j * m + i;
        _tri(a, a + m, a + 1);
        _tri(a + 1, a + m, a + m + 1);
      }
    }
  }

  /// A flat-shaded fan from [apex] over the open polyline [rim], every
  /// vertex sharing [normal] — one crisp facet with a curved outer edge.
  void fan(vm.Vector3 apex, List<vm.Vector3> rim, vm.Vector4 apexColor, vm.Vector4 rimColor, vm.Vector3 normal) {
    final n = normal.normalized();
    final a = _v(apex, n, apexColor);
    final ring = [for (final p in rim) _v(p, n, rimColor)];
    for (var i = 0; i < ring.length - 1; i++) {
      _tri(a, ring[i], ring[i + 1]);
    }
  }

  /// One seamless smooth surface from a signed distance field [f] (< 0
  /// inside), meshed by surface nets over [box] at grid spacing [cell].
  /// Each vertex is projected onto the zero set and lit by the field's
  /// gradient, so parts joined in [f] with a smooth-min blend into one
  /// skin — no creases where a tail or an arm meets the body. [color] sees
  /// each vertex and its outward normal.
  void implicit(
    double Function(vm.Vector3 p) f,
    vm.Aabb3 box,
    double cell,
    vm.Vector4 Function(vm.Vector3 p, vm.Vector3 n) color,
  ) {
    final lo = box.min;
    final nx = ((box.max.x - lo.x) / cell).ceil() + 1;
    final ny = ((box.max.y - lo.y) / cell).ceil() + 1;
    final nz = ((box.max.z - lo.z) / cell).ceil() + 1;
    int at(int i, int j, int k) => (k * ny + j) * nx + i;
    vm.Vector3 pt(int i, int j, int k) => vm.Vector3(lo.x + i * cell, lo.y + j * cell, lo.z + k * cell);

    final v = Float64List(nx * ny * nz);
    for (var k = 0; k < nz; k++) {
      for (var j = 0; j < ny; j++) {
        for (var i = 0; i < nx; i++) {
          v[at(i, j, k)] = f(pt(i, j, k));
        }
      }
    }

    vm.Vector3 grad(vm.Vector3 p) {
      final e = cell * 0.5;
      return vm.Vector3(
        f(p + vm.Vector3(e, 0, 0)) - f(p - vm.Vector3(e, 0, 0)),
        f(p + vm.Vector3(0, e, 0)) - f(p - vm.Vector3(0, e, 0)),
        f(p + vm.Vector3(0, 0, e)) - f(p - vm.Vector3(0, 0, e)),
      );
    }

    // One vertex per cell the surface crosses: the mean of its edge
    // crossings, then pulled onto the zero set.
    const corners = [
      [0, 0, 0], [1, 0, 0], [0, 1, 0], [1, 1, 0], //
      [0, 0, 1], [1, 0, 1], [0, 1, 1], [1, 1, 1],
    ];
    const edges = [
      [0, 1], [2, 3], [4, 5], [6, 7], [0, 2], [1, 3], //
      [4, 6], [5, 7], [0, 4], [1, 5], [2, 6], [3, 7],
    ];
    final cellVert = Int32List((nx - 1) * (ny - 1) * (nz - 1))..fillRange(0, (nx - 1) * (ny - 1) * (nz - 1), -1);
    int cidx(int i, int j, int k) => (k * (ny - 1) + j) * (nx - 1) + i;
    final cv = List<double>.filled(8, 0);
    for (var k = 0; k < nz - 1; k++) {
      for (var j = 0; j < ny - 1; j++) {
        for (var i = 0; i < nx - 1; i++) {
          var inside = 0;
          for (var c = 0; c < 8; c++) {
            final o = corners[c];
            cv[c] = v[at(i + o[0], j + o[1], k + o[2])];
            if (cv[c] < 0) inside++;
          }
          if (inside == 0 || inside == 8) continue;
          final p = vm.Vector3.zero();
          var n = 0;
          for (final e in edges) {
            final a = cv[e[0]], b = cv[e[1]];
            if ((a < 0) == (b < 0)) continue;
            final t = a / (a - b);
            final oa = corners[e[0]], ob = corners[e[1]];
            p.add(
              vm.Vector3(
                i + oa[0] + (ob[0] - oa[0]) * t,
                j + oa[1] + (ob[1] - oa[1]) * t,
                k + oa[2] + (ob[2] - oa[2]) * t,
              ),
            );
            n++;
          }
          p.scale(cell / n);
          p.add(lo);
          for (var it = 0; it < 3; it++) {
            final g = grad(p);
            final l2 = g.length2;
            if (l2 < 1e-12) break;
            final step = g * (f(p) * cell / l2);
            if (step.length > cell) break;
            p.sub(step);
          }
          final nn = grad(p)..normalize();
          cellVert[cidx(i, j, k)] = _v(p, nn, color(p, nn));
        }
      }
    }

    // One quad per grid edge with a sign change, joining the four cells
    // around it (winding is fixed up by [_tri]).
    void quad(int a, int b, int c, int d) {
      if (a < 0 || b < 0 || c < 0 || d < 0) return;
      _tri(a, b, c);
      _tri(a, c, d);
    }

    for (var k = 1; k < nz - 1; k++) {
      for (var j = 1; j < ny - 1; j++) {
        for (var i = 1; i < nx - 1; i++) {
          final s = v[at(i, j, k)] < 0;
          if (s != (v[at(i + 1, j, k)] < 0)) {
            quad(
              cellVert[cidx(i, j - 1, k - 1)],
              cellVert[cidx(i, j, k - 1)],
              cellVert[cidx(i, j, k)],
              cellVert[cidx(i, j - 1, k)],
            );
          }
          if (s != (v[at(i, j + 1, k)] < 0)) {
            quad(
              cellVert[cidx(i - 1, j, k - 1)],
              cellVert[cidx(i, j, k - 1)],
              cellVert[cidx(i, j, k)],
              cellVert[cidx(i - 1, j, k)],
            );
          }
          if (s != (v[at(i, j, k + 1)] < 0)) {
            quad(
              cellVert[cidx(i - 1, j - 1, k)],
              cellVert[cidx(i, j - 1, k)],
              cellVert[cidx(i, j, k)],
              cellVert[cidx(i - 1, j, k)],
            );
          }
        }
      }
    }
  }

  /// Moves everything added so far by [d] — e.g. to seat a finished body
  /// lower on its wheels without re-keying every part.
  void shift(vm.Vector3 d) {
    for (var i = 0; i < _pos.length; i += 3) {
      _pos[i] += d.x;
      _pos[i + 1] += d.y;
      _pos[i + 2] += d.z;
    }
  }

  /// Scales everything added so far by [s] about the origin — bakes a
  /// part's (non-uniform) size into its vertices, since a node's own scale
  /// must stay uniform or the lighting goes wrong. Normals take the inverse
  /// scale so they stay perpendicular to the stretched surface.
  void scale(vm.Vector3 s) {
    assert(s.x > 0 && s.y > 0 && s.z > 0, 'scale must be positive: a negative axis mirrors and flips winding');
    for (var i = 0; i < _pos.length; i += 3) {
      _pos[i] *= s.x;
      _pos[i + 1] *= s.y;
      _pos[i + 2] *= s.z;
      final n = vm.Vector3(_nrm[i] / s.x, _nrm[i + 1] / s.y, _nrm[i + 2] / s.z)..normalize();
      _nrm[i] = n.x;
      _nrm[i + 1] = n.y;
      _nrm[i + 2] = n.z;
    }
  }

  /// Axis-aligned bounds of everything added so far (after [xf]).
  vm.Aabb3 get bounds {
    final lo = vm.Vector3.all(double.infinity);
    final hi = vm.Vector3.all(-double.infinity);
    for (var i = 0; i < _pos.length; i += 3) {
      final p = vm.Vector3(_pos[i], _pos[i + 1], _pos[i + 2]);
      vm.Vector3.min(lo, p, lo);
      vm.Vector3.max(hi, p, hi);
    }
    return vm.Aabb3.minMax(lo, hi);
  }

  MeshGeometry build() => MeshGeometry.fromArrays(
    positions: Float32List.fromList(_pos),
    normals: Float32List.fromList(_nrm),
    texCoords: Float32List.fromList(_uv),
    colors: Float32List.fromList(_col),
    indices: _idx,
  );
}
