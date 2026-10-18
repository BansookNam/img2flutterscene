# Migration ledger: img2threejs → img2flutterscene

This repository started on 2026-10-18 as a copy of the tracked files of
[img2threejs](https://github.com/img2threejs/img2threejs) at `d508b59` (v2.0.0), plus the
flutter_scene runtime from Blue Heaven (`lib/common/scene/part_builder.dart` and the
`image-to-3d-fish` skill). It has no shared git history with either.

The intake → spec → gate pipeline is renderer-agnostic and was kept whole, so the inherited suite
still passes (1416 tests on the day of the copy). Three.js-coupled pieces were **kept, not deleted**,
because shared modules import them (the validator imports `subdivision`/`visual_hull`, the Dart
generator imports the three.js generator's gates). Each one is listed below with its status. Update
this file in the same change that moves a row.

Status words: **ported** (works on the flutter_scene target, tested), **partial** (works with named
gaps), **not ported** (three.js only; must not be presented as flutter_scene evidence), **shared**
(target-agnostic, used as-is), **removed**.

## Build and runtime

| Piece | Status | Notes |
|---|---|---|
| `forge/stage3_build/generate_flutter_scene.py` | partial | New. Shares the three.js generator's gates. box, sphere, ellipsoid, cylinder, cone, capsule, torus, lathe, extrude, attachment frustums. Blocks on everything else unless `--allow-partial` |
| implicit SDF components (`geometryDescriptor.sdf`) | not ported | `PartBuilder.implicit` (surface nets) exists; needs a translator from `_shared/sdf_primitives.py` descriptors to a Dart SDF closure |
| curve-sweep, tapered-sweep, tube, ground-blade, plane-card | not ported | `PartBuilder.loft` / `patch` / `bar` / `ridge` are the building blocks |
| subdivision (`subdivisionIterations`) | not ported | three.js emits Catmull-Clark in TS; needs a Dart port or a Python bake |
| visual hull | not ported | |
| decimation | not ported | |
| `repetitionSystems` (instancing) | not ported | flutter_scene has `InstancedMesh` |
| `edgeTreatment`, `deformationStack`, `vertexPaint`, `rootTipGradient`, `standProud`, `localFeatures` | not ported | Built without them; generator lists each as `UNAPPLIED` |
| material scalars beyond metalness/roughness (clearcoat, sheen, transmission, maps) | not ported | `PhysicallyBasedMaterial` supports them; spec → material mapping not written |
| lighting rig / camera from spec (`lightingFromPhoto`, `referenceCamera`) | not ported | The lab uses a fixed key light + IBL |
| `forge/stage3_build/generate_threejs_factory.py` | shared (legacy) | Still the authority for gate functions the Dart generator imports; move those into `_shared/` before deleting it |
| `forge/stage3_build/emit_target.py` (GLB etc. export targets) | not ported | |
| `runtime/` (Dart package `img2flutterscene`) | ported | `PartBuilder` copied verbatim from Blue Heaven plus `scale()`; unit primitives; `SculptModel` with the three.js frame |
| coordinate frame | ported | `SculptModel.node` wraps the spec root in `scale(1, 1, −1)`; verified in the primitive gallery (front/90° shots) |

## Rendering, capture and review

| Piece | Status | Notes |
|---|---|---|
| `lab/` app + `scripts/lab_shot.sh` | ported | macOS. Turntable angles in one launch, backdrops, side-by-side layout, explode |
| `forge/stage4_review/*` image gates (diagnose_render, multi-angle, turntable, interior difference, comparison sheet, divine eye, …) | shared | Read PNG/JSON; feed them lab shots. Not yet exercised end-to-end on a real reconstruction |
| `self_intersection.py` input (`export_mesh_geometry.mjs`) | not ported | Needs a lab mode that dumps world-space triangles as JSON; until then the gate is `unevaluated` |
| `attachment_anchor.py --measured` input | not ported | Same: needs measured node positions from the lab |
| `forge/stage4_review/render_bridge.py`, `scripts/capture_threejs_playwright.py` | not ported | Browser/three.js capture |
| GLB-mediated render-fidelity track (six-pass capture) | not ported | Needs semantic-ID / depth / normal passes from flutter_scene |
| `scripts/trace_silhouette.py` | partial | Copied from Blue Heaven's `trace_svg.py`. Works; still fish-shaped (snout/tail wording, horizontal-length normalisation). Needs numpy/scipy/scikit-image/Pillow, so it lives outside the stdlib forge |

## Rig and animation

| Piece | Status | Notes |
|---|---|---|
| `forge/stage5_rig/*` (emit_rig, emit_animation_runtime, skinning, gates) | not ported | Emits `THREE.Skeleton` / TS runtime. flutter_scene has `Skin` and an animation system |
| `animated-character` profile (plugin) | not ported | Its steps assume the three.js rig emitter |

## Spec, intake and state

| Piece | Status | Notes |
|---|---|---|
| `forge/stage1_intake/*`, `forge/stage2_spec/*`, `forge/_shared/*`, `forge/state.py`, `forge/next.py` | shared | Unchanged |
| state directory `.img2threejs/` | shared (to rename) | Hard-coded in the forge and asserted by tests; rename to `.img2flutterscene/` in one change across forge, tests and docs |
| domain plugins via the `img2` harness | unknown | Plugins may emit three.js-specific augmentation; untested on this target |
| `grimoire/` | shared | Plus `grimoire/build/flutter_scene_target.md`. Three.js-specific notes (`stylized_hair_threejs.md`, `threejs_*`, `python_threejs_render_bridge.md`) describe the legacy target |
| `docs/` | shared (legacy wording) | Most docs still say three.js; the GLB_* prompts and showcase material describe img2threejs |
| `integrations/` | shared | Vision adapters (`integrations/vision`) are target-agnostic; `glb_character_pipeline` is three.js/GLB |

## Removed in the copy

`bin/` and `package.json` (img2threejs npm installer), the npm/GitHub release and issue-triage
workflows, `scripts/issue_triage.py` with its test and `docs/issue-triage.md`, `.github/FUNDING.yml`,
`.github/release.yml`, and the img2threejs logo and sponsor marks. `.gitignore` no longer ignores
`runtime/` (img2threejs used that name for a local browser bundle; here it is the Dart package).

## Known quirk found during the copy

`transform.scale`, when present, overrides `dimensions` in both generators (`scale_triple`). The
forge's own conformance fixture (`forge/tests/fixtures/reference_target_conformance_spec.json`)
gives every part `scale: [1, 1, 1]`, so it builds as overlapping unit cubes on **both** targets. The
lab's smoke model uses a copy with the redundant `scale` removed (`lab/specs/sample_hard_case.json`).
Worth fixing upstream (either the fixture or the precedence rule).
