import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// Surface views for inspecting a model, each a flutter_scene debug channel.
enum InspectView {
  lit('Lit', SurfaceDebugChannel.none),
  normals('Normals', SurfaceDebugChannel.worldNormal),
  faces('Face orientation', SurfaceDebugChannel.faceOrientation),
  albedo('Vertex colour', SurfaceDebugChannel.vertexColor),
  roughness('Roughness', SurfaceDebugChannel.roughness),
  metallic('Metallic', SurfaceDebugChannel.metallic),
  parts('Part colours', SurfaceDebugChannel.objectColor);

  const InspectView(this.label, this.channel);
  final String label;
  final SurfaceDebugChannel channel;

  String get hint => switch (this) {
    InspectView.faces => 'Blue = front faces. Red where you should see the outside means wrong winding.',
    InspectView.normals => 'World-space normals as colour; seams or speckles mean broken normals.',
    InspectView.parts => 'One flat colour per node — shows how the model is split into parts.',
    _ => '',
  };
}

enum Backdrop {
  dark('Dark', Color(0xFF14161C)),
  mid('Grey', Color(0xFF6B6F78)),
  light('Light', Color(0xFFF2EFE8)),
  white('White', Color(0xFFFFFFFF));

  const Backdrop(this.label, this.color);
  final String label;
  final Color color;
}

enum ReferenceMode {
  off('Off'),
  side('Side by side'),
  overlay('Overlay');

  const ReferenceMode(this.label);
  final String label;
}

/// Everything the inspector panels change about how the model is shown.
/// Nothing here changes the model itself.
class ViewSettings extends ChangeNotifier {
  // Light
  double keyIntensity = 3.0;
  double lightAzimuth = 35; // degrees, 0 = from the front, + = from the right
  double lightElevation = 45; // degrees above the horizon
  bool lightFollowsCamera = true;
  double environmentIntensity = 1.0;
  double exposure = 1.0;
  bool toneMapping = true;

  // View
  InspectView view = InspectView.lit;
  bool wireframe = false;
  bool grid = true;
  bool autoRotate = false;
  double fovDegrees = 30;
  Backdrop backdrop = Backdrop.dark;
  ReferenceMode reference = ReferenceMode.side;
  double referenceOpacity = 0.5;

  // Parts
  double explode = 0; // fraction of the model's radius
  final Set<String> hidden = {};
  String? selected;
  bool isolate = false;
  bool tintSelected = true;

  /// A part the viewer should centre and zoom on; it clears this once done.
  String? focusRequest;

  void update(void Function(ViewSettings s) change) {
    change(this);
    notifyListeners();
  }

  /// The light's travel direction for a camera at [cameraYaw] (radians).
  /// Azimuth is measured from the viewer's side: 0 = from behind the camera,
  /// + = from screen-right. With [lightFollowsCamera] off it is measured from
  /// the front view instead, so the light stays put while you orbit.
  vm.Vector3 lightDirection(double cameraYaw) {
    final yaw = lightFollowsCamera ? cameraYaw : 0.0;
    final az = lightAzimuth * vm.degrees2Radians;
    final el = lightElevation * vm.degrees2Radians;
    final toward = horizontalEye(yaw);
    final right = screenRight(yaw);
    final source = (right * math.sin(az) + toward * math.cos(az)) * math.cos(el) + vm.Vector3(0, math.sin(el), 0);
    return -source;
  }

  void resetLight() => update((s) {
    s.keyIntensity = 3.0;
    s.lightAzimuth = 35;
    s.lightElevation = 45;
    s.lightFollowsCamera = true;
    s.environmentIntensity = 1.0;
    s.exposure = 1.0;
    s.toneMapping = true;
  });
}

/// Unit vector from the target toward a camera at [yaw], in the horizontal
/// plane. Yaw 0 is the front view, from −Z.
vm.Vector3 horizontalEye(double yaw) => vm.Vector3(-math.sin(yaw), 0, -math.cos(yaw));

/// Screen-right for a camera at [yaw]. flutter_scene shows +X on the right
/// from −Z (verified in the lab), so this is eye × up, not up × eye.
vm.Vector3 screenRight(double yaw) => vm.Vector3(math.cos(yaw), 0, -math.sin(yaw));

/// The orbit camera: yaw/pitch about [target] at [distance]. Yaw 0 looks at
/// the model's front (from −Z, see the runtime's threeJsFrame); yaw 90 shows
/// the model's own right side, like the lab and turntable_gate.py.
class OrbitController extends ChangeNotifier {
  double yaw = 0;
  double pitch = 12 * vm.degrees2Radians;

  /// Multiple of the distance that just fits the model.
  double zoom = 1;
  vm.Vector3 pan = vm.Vector3.zero();

  void orbit(double dYaw, double dPitch) {
    yaw += dYaw;
    pitch = (pitch + dPitch).clamp(-89 * vm.degrees2Radians, 89 * vm.degrees2Radians);
    notifyListeners();
  }

  void zoomBy(double factor) {
    zoom = (zoom * factor).clamp(0.05, 20);
    notifyListeners();
  }

  void panBy(vm.Vector3 delta) {
    pan += delta;
    notifyListeners();
  }

  /// Centres the view on [panTo] (offset from the model's centre) at [zoomTo].
  void frame(vm.Vector3 panTo, double zoomTo) {
    pan = panTo;
    zoom = zoomTo.clamp(0.05, 20);
    notifyListeners();
  }

  void preset(double yawDeg, double pitchDeg) {
    yaw = yawDeg * vm.degrees2Radians;
    pitch = pitchDeg * vm.degrees2Radians;
    notifyListeners();
  }

  void reset() {
    yaw = 0;
    pitch = 12 * vm.degrees2Radians;
    zoom = 1;
    pan = vm.Vector3.zero();
    notifyListeners();
  }

  /// Unit vector from the target toward the camera.
  vm.Vector3 get eyeDirection =>
      vm.Vector3(-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch));
}
