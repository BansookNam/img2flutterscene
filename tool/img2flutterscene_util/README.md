# img2flutterscene util

A macOS companion app for the img2flutterscene skill: pick an image, press **Convert**, and watch the
model take shape in a live 3D preview.

![The util app](../../docs/images/util-app.png)

## Run

```bash
cd tool/img2flutterscene_util
flutter run -d macos          # or: flutter build macos, then open the .app
```

The app finds the checkout it was built in (it walks up from its own executable to the folder
holding `SKILL.md`). Otherwise set `IMG2FLUTTERSCENE_ROOT`, or click the path under the title and
choose the folder.

**Requirements:** Flutter ≥ 3.47 with Flutter GPU, Python ≥ 3.10, and
[Claude Code](https://claude.com/claude-code) logged in. `python3` and `claude` must be on your
**login shell** PATH, because the app starts them through `zsh -l`.

## What it does

| | |
|---|---|
| **New from image…** | Copies the image into `work/<name>-<date>/` (gitignored, so your models never conflict with a `git pull`). |
| **Convert** | Runs the skill headlessly: `claude -p … --output-format stream-json` in the checkout, one session per model. The log streams into the bottom panel. |
| **Continue / Ask Claude** | Resumes the same session (`--resume`), either from the local state gate or with your own instruction ("the lid is too thin"). |
| **Live preview** | Whenever the spec changes, the app re-runs `generate_flutter_scene.py --format scene-json` and reloads the model, with no compile step. |
| **Export Dart** | Writes `work/<id>/model.dart`, the factory to drop into your app. |

### Inspecting the model

- **Camera:** drag to orbit; shift-drag or right-drag to pan; scroll or pinch to zoom; double-click
  to reset. Keys (click the view first): `F R B L T` for front/right/back/left/top, `0` reset,
  `W` wireframe, `G` grid, `Space` auto-rotate. Yaw 90 shows the model's own right side, matching
  the lab and the turntable gate.
- **Light:** key light strength, direction (+ = from screen-right), height, follow-camera toggle,
  ambient (IBL), exposure, and ACES tone mapping.
- **View:** surface views from flutter_scene's debug channels:
  - **Face orientation:** a red face you should see from outside means wrong winding.
  - **Normals**, **vertex colour**, **roughness**, **metallic**, and **part colours**.
  - Plus the wireframe overlay, field of view, backdrop, floor grid, and the reference image beside
    the model or overlaid at adjustable opacity (line it up in Front view).
- **Parts:** the component tree with per-part visibility, isolate, tint, focus-the-camera, and a
  hierarchical explode slider.
- **Info:** pass, parts and materials; vertices per part (where the budget goes); what the generator
  could **not** build and which refinements it built **without**. These come straight from the
  generator, so an approximate preview never passes for a finished one.
- **Screenshot** (camera icon) saves the viewport to `work/<id>/shots/`.

## Permissions

A headless run cannot answer permission prompts, so anything outside the allow-list is denied:

- **Skill commands only** (default): file edits plus `python3`, `scripts/lab_shot.sh`,
  `flutter`/`dart`, and a few file utilities.
- **Bypass all permissions:** `--permission-mode bypassPermissions`. Only on a checkout you trust.

## Develop

```bash
flutter test && flutter analyze
```

`--dart-define=UTIL_SHOT=/abs/out.png` saves the whole window after six seconds and quits.
Combine it with `UTIL_SELECT=<work id>`, `UTIL_TAB=<0-4>` and
`UTIL_SETUP=view=faces,wire,explode=0.5,yaw=35,pitch=20,ref=overlay,light=6,az=80,el=20,focus=<part>`
to check a UI change by reading the PNG back.
