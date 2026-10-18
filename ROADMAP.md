# Roadmap

Ordered by what unblocks real reconstructions soonest. Each item moves a row in `MIGRATION.md`;
nothing here is implemented until that ledger says so.

## M1 — first real reconstruction end to end
- Run one subject through the whole loop on this target: intake → spec → generate → lab shots →
  `diagnose_render.py` / `turntable_gate.py` / comparison sheet → `append_review.py`, and record
  what breaks.
- Lab mesh export (world-space triangles + node positions as JSON) so `self_intersection.py` and
  `attachment_anchor.py --measured` evaluate instead of reporting `unevaluated`.
- Generalise `scripts/trace_silhouette.py` beyond fish (subject-neutral wording, aspect-aware
  normalisation) and wire it next to `diagnose_render.py`.

## M2 — geometry coverage
- Implicit SDF components → `PartBuilder.implicit` (translate `_shared/sdf_primitives.py`
  descriptors into Dart closures; respect `SDF_MAX_RESOLUTION`).
- Sweeps (curve-sweep, tapered-sweep, tube, ground-blade) on `loft` / `patch`.
- Repetition systems on `InstancedMesh`.
- `edgeTreatment` (rounded boxes), `deformationStack` (taper/bend/twist), vertex paint.

## M3 — materials and look
- Map the spec's full material record (clearcoat, sheen, transmission, emissive, opacity) onto
  `PhysicallyBasedMaterial`; a `.fmat` route for per-pixel patterns.
- Lighting from `lightingFromPhoto` / camera from `referenceCamera` in the lab.

## M4 — cleanup
- Move the gate functions the Dart generator imports into `forge/_shared/`, then retire or
  quarantine the three.js generator and its tests.
- Rename the state directory `.img2threejs/` → `.img2flutterscene/` across forge, tests, docs.
- Sweep `docs/` and `grimoire/` wording; drop three.js-only documents that will not be ported.

## Later
- Rig and animation on flutter_scene `Skin` (port of `stage5_rig/`).
- GLB-mediated render-fidelity track with flutter_scene passes.
