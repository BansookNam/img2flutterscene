# Shared project instructions

This repository is the canonical source for the `img2flutterscene` skill: image → procedural
flutter_scene model in Dart. It is a migration of img2threejs; `MIGRATION.md` is the ledger of what
is ported. Host entrypoints (`~/.claude/skills/img2flutterscene`,
`~/.codex/skills/img2flutterscene`) should be symlinks to one checkout — never independent copies.

## Change rules

- Preserve the code-only procedural contract; do not silently download meshes or art packs.
- Keep claims honest: a stage is only "ported" when `MIGRATION.md` says so and a test covers it.
  Three.js-only stages must never be reported as flutter_scene evidence.
- Move a `MIGRATION.md` row in the same change that ports (or removes) the piece.
- Treat `forge/` as deterministic stdlib tooling and `grimoire/` as routed reference material.
  Tools with third-party Python deps live in `scripts/`, not `forge/`.
- Specs stay in three.js's frame (right-handed, +Y up, front +Z). The flip into flutter_scene lives
  in one place, `SculptModel.node` — never compensate for it in specs or the generator.
- `runtime/lib/src/part_builder.dart` mirrors Blue Heaven's; keep additions small and in its style
  so the two can be synced.
- A user's model lives in `work/<id>/` (gitignored), never in tracked files; see SKILL.md "Local
  work". Only `lab/` samples the user asked to ship are committed.
- Keep backward compatibility for existing sculpt specs unless a migration is explicitly planned.
- When changing schema, gates, generators, runtime or review behavior, add or update focused tests.
- Keep `SKILL.md`, `README.md`, `CHANGELOG.md`, `ROADMAP.md` and `MIGRATION.md` consistent when
  release-facing behavior changes.
- Reference the img2threejs showcase through `IMG2THREEJS_SHOWCASE_ROOT`, never an absolute path.

## Verification

```bash
python3 -m unittest discover -s forge/tests -p 'test_*.py'
(cd runtime && flutter test && flutter analyze)
(cd lab && flutter analyze)
(cd tool/img2flutterscene_util && flutter test && flutter analyze)
```

With `flutter` on the PATH, the Python suite compiles generated Dart against `runtime/`; set
`IMG2FLUTTERSCENE_REQUIRE_FLUTTER=1` to fail instead of skip without it. The inherited TypeScript
gates need `IMG2THREEJS_SHOWCASE_ROOT` and only cover the legacy three.js generator.

Do not report completion without reading the fresh outputs. For visual reconstruction changes,
structural tests and screenshot/reference-loop validation are separate required gates.

## Mandatory visual screenshot gate

For every visual reconstruction task, a readable screenshot is a hard prerequisite for visual
implementation claims and completion:

1. Before accepting visual results, verify the lab builds and `scripts/lab_shot.sh` captures it
   (Flutter GPU on, macOS sandbox copy-out working).
2. Save fresh PNG screenshots inside the workspace, including the fixed reference view and the
   required turntable views (`0,90,180,270`). Inline previews alone are not evidence.
3. Read the saved screenshots back with an image-capable tool and verify they contain the rendered
   model at the expected dimensions. A screenshot that cannot be opened or visually read is a failed
   gate.
4. Produce and retain a side-by-side reference/render comparison, semantic image scoring,
   pixel/feature comparison, and the `diagnose_render.py` output for the saved render before
   reporting visual validation.
5. If capture, file write, readback, comparison, scoring, or diagnosis fails, stop the visual
   workflow and repair the tooling first. Do not infer visual evidence from runtime readiness,
   structural tests, `flutter analyze`, inline previews, or code review, and do not claim the
   visual gate passed.
