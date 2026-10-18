# sculpt_lab

The reconstruction lab: a generated model beside its reference image, on a turntable, with scripted
screenshots for the review gates. See `../grimoire/build/flutter_scene_target.md`.

```bash
flutter run -d macos                                   # interactive (Space spin, ←/→ angle, E explode)
../scripts/lab_shot.sh <model> <name> 0,90,180,270 ../.lab-shots   # scripted capture
```

Models are registered in `lib/models/models.dart`; generated factories land in `lib/models/` from
`forge/stage3_build/generate_flutter_scene.py`.
