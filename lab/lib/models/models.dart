import 'package:img2flutterscene/img2flutterscene.dart';

import 'primitive_gallery.dart';
import 'sample_hard_case.dart';

/// One reconstruction the lab can show: its generated factory and the
/// reference image it is matched against (in assets/references/).
class LabModel {
  const LabModel(this.id, this.name, this.build, {this.reference});

  final String id;
  final String name;
  final SculptModel Function() build;
  final String? reference;
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

LabModel? labModelById(String id) {
  for (final m in labModels) {
    if (m.id == id) return m;
  }
  return null;
}
