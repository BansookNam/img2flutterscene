import 'dart:convert';
import 'dart:io';

import 'package:img2flutterscene/img2flutterscene.dart';

import 'primitive_gallery.dart';
import 'sample_hard_case.dart';

/// One reconstruction the lab can show: its generated factory and the
/// reference image it is matched against (in assets/references/).
class LabModel {
  const LabModel(this.id, this.name, this.build, {this.reference, this.referenceFile});

  final String id;
  final String name;
  final SculptModel Function() build;

  /// Reference image as an asset path, or as a file on disk (local work).
  final String? reference;
  final String? referenceFile;
}

/// A model loaded at run time from a scene-json file (`--dart-define=SCENE=`),
/// typically `work/<id>/model.scene.json` — local, gitignored work that is
/// never registered in this file. Its reference is the first
/// `reference.*` beside it unless `--dart-define=REF=` names one.
LabModel? sceneFileModel() {
  const path = String.fromEnvironment('SCENE');
  if (path.isEmpty) return null;
  final file = File(path);
  SceneDescription read() => SceneDescription.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, Object?>);
  const ref = String.fromEnvironment('REF');
  final siblings = file.parent.existsSync() ? file.parent.listSync().whereType<File>() : const <File>[];
  final found = siblings.where((f) => f.uri.pathSegments.last.startsWith('reference.')).map((f) => f.path);
  return LabModel(
    'scene',
    '${read().target} (${read().pass})',
    () => loadSceneDescription(read()),
    referenceFile: ref.isNotEmpty ? ref : found.firstOrNull,
  );
}

/// Every model in the lab. Generate a factory into lib/models/ with
/// forge/stage3_build/generate_flutter_scene.py, then list it here.
const labModels = <LabModel>[
  // Runtime check: every unit primitive, hand-written.
  LabModel('primitive_gallery', 'Primitive gallery', createPrimitiveGalleryModel),
  // Codegen smoke model from lab/specs/sample_hard_case.json (the forge's
  // conformance fixture); its reference photo is not in the repo.
  LabModel('sample_hard_case', 'Hard case (fixture)', createTradeItHardCaseModel),
];

/// The scene-file model (if any) first, then the registered ones.
final allLabModels = [?sceneFileModel(), ...labModels];

LabModel? labModelById(String id) {
  for (final m in allLabModels) {
    if (m.id == id) return m;
  }
  return null;
}
