# Changelog

All notable changes to img2flutterscene. History before 0.1.0 is img2threejs's own
(`v2.0.0`, commit `d508b59`), from which this project was copied.

## [0.2.0] - 2026-10-18

### Added
- `tool/img2flutterscene_util`: macOS app. New from image → **Convert** runs the skill through
  headless Claude Code (`claude -p --output-format stream-json`, one session per model, with
  Continue / Ask). Live preview with an orbit camera, light and exposure controls, flutter_scene
  inspection views (face orientation, normals, part colours, roughness, metallic, vertex colour),
  wireframe, reference side-by-side or overlay, a parts tree (visibility, isolate, tint, focus,
  hierarchical explode), per-part vertex counts, omissions and unapplied refinements, screenshots,
  Dart export.
- `generate_flutter_scene.py --format scene-json`: the same model as data. Dart and JSON both render
  from one scene description (`build_scene`); the Dart output is byte-identical to 0.1.0.
- Runtime `SceneDescription` / `loadSceneDescription` / `buildPartGeometry`: build a model from
  scene-json at run time. `SculptModel.meshOf(id)`.
- `scripts/lab_shot.sh` and the lab accept a scene-json file (`--dart-define=SCENE=`), so local
  models are captured without registering them.
- SKILL.md "Local work" contract: a user's model lives in `work/<id>/` (gitignored) and never in
  tracked files, so `git pull` stays conflict-free.

### Changed
- `SculptModel.explode` moves every part along its offset from its parent (it used to move only
  top-level parts, which left a typical single-root spec unexploded).
- The lab runs without the macOS sandbox (it reads scene files from `work/`).

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
