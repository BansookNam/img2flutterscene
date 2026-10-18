# Changelog

All notable changes to img2flutterscene. History before 0.1.0 is img2threejs's own
(`v2.0.0`, commit `d508b59`), from which this project was copied.

## [0.1.0] - 2026-10-18

Initial migration of img2threejs to the flutter_scene target. See `MIGRATION.md` for exact status.

### Added
- `forge/stage3_build/generate_flutter_scene.py`: spec → Dart flutter_scene factory. Shares the
  three.js generator's strict-quality, pass-lock and pass-gap gates. Emits box, sphere, ellipsoid,
  cylinder, cone, capsule, torus, lathe, extrude and attachment-endpoint frustums; blocks on any
  other geometry (`flutter-scene-coverage`) unless `--allow-partial`, which names each omission;
  lists unapplied refinements as `UNAPPLIED`.
- `runtime/`: Dart package `img2flutterscene` — Blue Heaven's `PartBuilder` (+ `scale()`), unit
  primitives sized like the three.js generator's, `SculptModel` with a three.js-frame wrapper
  (`scale(1, 1, −1)`) so specs keep their handedness.
- `lab/`: Flutter macOS/iOS/Android app with Flutter GPU enabled — model beside reference,
  turntable, explode, scripted multi-angle screenshots; a primitive gallery runtime check.
- `scripts/lab_shot.sh` (capture) and `scripts/trace_silhouette.py` (silhouette trace + IoU, from
  Blue Heaven).
- `grimoire/build/flutter_scene_target.md`: frame, hierarchy, material, shader and capture rules.
- `forge/tests/test_generate_flutter_scene.py`, including a gate that compiles generated Dart
  against `runtime/` with `flutter analyze`.

### Removed
- img2threejs's npm installer (`bin/`, `package.json`), release/publish/issue-triage workflows and
  scripts, funding config, logo and sponsor marks.
