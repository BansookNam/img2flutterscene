#!/usr/bin/env python3
"""Generate a Dart flutter_scene model factory from an ObjectSculptSpec.

The flutter_scene counterpart of `generate_threejs_factory.py`. It shares that
generator's gates verbatim (strict-quality, pass lock, pass-specific gaps) by
importing them, so the two targets cannot disagree about *whether* a spec may
be built -- only about how the result is drawn.

Output is one Dart file defining `SculptModel create<Name>Model()`, built on
the `img2flutterscene` runtime package (`runtime/`): one pivot `Node` per
component at the spec's position/rotation, parented by spec id, with the
component's dimensions baked into its own `PartBuilder` mesh (never onto the
node: flutter_scene lights non-uniformly scaled nodes wrongly). Albedo goes
into vertex colours; each spec material becomes one shared
`PhysicallyBasedMaterial` carrying metalness/roughness.

Spec features fall in three groups:
  supported    emitted (see SUPPORTED_PRIMITIVES)
  unapplied    refinements the shape survives without (bevels, deformation
               stacks, paint): emitted WITHOUT them, each named in the file
               header and on stderr, so an approximate part never passes for
               a finished one
  unsupported  no Dart construction yet: generation refuses (exit 2) unless
               --allow-partial, which omits them and names them in the header

`--format scene-json` writes the same model as data (`SCENE_FORMAT`) for the runtime's loader,
so a running app can preview a spec without compiling generated Dart.

Exit codes: 0 written, 1 usage/validation error, 2 blocked (strict-quality or
unsupported features).
"""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

_FORGE_ROOT = Path(__file__).resolve().parent.parent
sys.path[:0] = [str(_FORGE_ROOT), str(_FORGE_ROOT / "_shared"), str(_FORGE_ROOT / "stage2_spec"), str(Path(__file__).resolve().parent)]
from generate_threejs_factory import (  # noqa: E402
    assert_pass_unlocked,
    blocked_report,
    decimate_ratio,
    emit_blocked,
    filter_components_for_pass,
    load_spec,
    material_base_value,
    pascal_case,
    scale_triple,
    strict_quality_failures,
    subdivision_iterations,
    unlocked_pass,
)
from orchestrate_passes import pass_specific_gaps  # noqa: E402
from subdivision import segments_for_spec  # noqa: E402
from validate_sculpt_spec import ATTACHMENT_PRIMITIVES  # noqa: E402

SUPPORTED_PRIMITIVES = {"box", "sphere", "ellipsoid", "cylinder", "cone", "capsule", "torus", "lathe", "extrude"}
FALLBACK_COLOR = "#8A7A5F"
# Descriptor keys the emitter does not act on yet; the part is still built,
# but the header says what it is missing.
UNAPPLIED_DESCRIPTOR_KEYS = ("edgeTreatment", "deformationStack", "vertexPaint", "rootTipGradient", "standProud")


def dart_double(value: Any, fallback: float = 0.0) -> str:
    number = float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else fallback
    text = f"{round(number, 6):.6f}".rstrip("0")
    return text + "0" if text.endswith(".") else text


def dart_string(value: str) -> str:
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$").replace("\n", "\\n") + "'"


def triple(values: Any, fallback: tuple[float, float, float] = (0.0, 0.0, 0.0)) -> list[float]:
    if isinstance(values, list) and len(values) == 3 and all(
        isinstance(v, (int, float)) and not isinstance(v, bool) for v in values
    ):
        return [float(v) for v in values]
    return list(fallback)


def argb(color: Any) -> str:
    text = color if isinstance(color, str) else FALLBACK_COLOR
    if re.fullmatch(r"#[0-9A-Fa-f]{3}", text):
        text = "#" + "".join(ch * 2 for ch in text[1:])
    if not re.fullmatch(r"#[0-9A-Fa-f]{6}", text):
        text = FALLBACK_COLOR
    return "0xFF" + text[1:].upper()


def material_color(material: dict[str, Any] | None) -> str:
    if not isinstance(material, dict):
        return FALLBACK_COLOR
    albedo = material.get("albedo") if isinstance(material.get("albedo"), dict) else {}
    for value in (material.get("baseColor"), material.get("color"), albedo.get("dominant")):
        if isinstance(value, str) and value.strip():
            return value
    return FALLBACK_COLOR


def descriptor_of(component: dict[str, Any]) -> dict[str, Any]:
    descriptor = component.get("geometryDescriptor")
    return descriptor if isinstance(descriptor, dict) else {}


def classify(component: dict[str, Any]) -> tuple[list[str], list[str]]:
    """(unsupported, unapplied) feature names for one component."""
    primitive = str(component.get("primitive") or "box")
    descriptor = descriptor_of(component)
    unsupported: list[str] = []
    if descriptor.get("sdf") is not None:
        unsupported.append("implicit SDF surface (geometryDescriptor.sdf)")
    elif descriptor.get("visualHull") is not None:
        unsupported.append("visual hull (geometryDescriptor.visualHull)")
    elif primitive not in SUPPORTED_PRIMITIVES and attachment_endpoint(component) is None:
        unsupported.append(f"primitive {primitive!r}")
    if subdivision_iterations(component) > 0:
        unsupported.append("subdivision surface")
    if decimate_ratio(component) is not None:
        unsupported.append("decimation (geometryDescriptor.decimate)")
    profile = descriptor.get("profile2D")
    if primitive == "extrude" and isinstance(profile, dict) and (profile.get("holes") or profile.get("ovalHoles")):
        unsupported.append("extrude holes (profile2D.holes / ovalHoles)")
    unapplied = [f"geometryDescriptor.{key}" for key in UNAPPLIED_DESCRIPTOR_KEYS if descriptor.get(key)]
    if component.get("localFeatures"):
        unapplied.append("localFeatures (detail inventory is not modelled yet)")
    return unsupported, unapplied


def _number(value: Any, fallback: float) -> float:
    return float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else fallback


def attachment_endpoint(component: dict[str, Any]) -> dict[str, Any] | None:
    """The three.js generator's `makeAttachmentEndpoint`, evaluated at generation time.

    An attachment primitive (cylinder, cone, capsule, tube, curve-sweep) with an
    `attachment` block is built as a frustum between the measured endpoints instead of
    its own primitive: the pivot sits at `localStart` (keeping the authored rotation),
    the mesh at the segment's midpoint turned from +Y onto it. Implicit components keep
    their own placement. None when the component does not take this path.
    """
    attachment = component.get("attachment")
    if str(component.get("primitive") or "") not in ATTACHMENT_PRIMITIVES or not isinstance(attachment, dict):
        return None
    if descriptor_of(component).get("sdf") is not None and component.get("topologyClass") == "implicit":
        return None
    start = triple(attachment.get("localStart"), (0.0, 0.0, 0.0))
    end = triple(attachment.get("localEnd"), (0.0, 1.0, 0.0))
    delta = [e - s for s, e in zip(start, end)]
    length = math.sqrt(sum(d * d for d in delta))
    if length <= 0.0001:
        return None
    d = [v / length for v in delta]
    base_radius = max(0.005, _number(attachment.get("baseRadius"), 0.06))
    end_radius = max(0.003, _number(attachment.get("endRadius"), base_radius * 0.55))
    # THREE.Quaternion.setFromUnitVectors((0, 1, 0), d).
    r = d[1] + 1
    if r < 1e-6:
        q = [0.0, 0.0, 1.0, 0.0]
    else:
        q = [d[2], 0.0, -d[0], r]
        n = math.sqrt(sum(v * v for v in q))
        q = [v / n for v in q]
    return {
        "start": start,
        "midpoint": [v * 0.5 for v in delta],
        "quaternion": q,
        "length": length,
        "baseRadius": base_radius,
        "endRadius": end_radius,
    }


SCENE_FORMAT = "img2flutterscene.scene/1"


def r6(value: float) -> float:
    """Round like `dart_double`, so the Dart text and the scene JSON carry identical numbers."""
    out = round(float(value), 6)
    return 0.0 if out == 0 else out


def geometry_op(component: dict[str, Any], segments: dict[str, int]) -> dict[str, Any]:
    """The component's unit-sized shape as one op: a PartBuilder call by name plus its arguments.

    Ops are the shared vocabulary of both outputs -- `dart_geometry_call` writes one as Dart, and
    the runtime's scene loader (`runtime/lib/src/scene_description.dart`) replays it.
    """
    primitive = str(component.get("primitive") or "box")
    descriptor = descriptor_of(component)
    if primitive == "box":
        return {"op": "box", "seg": segments["BOX_SEGMENTS"]}
    if primitive in {"sphere", "ellipsoid"}:
        return {"op": "sphere", "seg": segments["SPHERE_WIDTH_SEGMENTS"], "rings": segments["SPHERE_HEIGHT_SEGMENTS"]}
    if primitive == "cylinder":
        return {"op": "cylinder", "seg": segments["CYLINDER_RADIAL_SEGMENTS"]}
    if primitive == "cone":
        return {"op": "cone", "seg": segments["CYLINDER_RADIAL_SEGMENTS"]}
    if primitive == "capsule":
        return {"op": "capsule", "seg": segments["CAPSULE_RADIAL_SEGMENTS"], "capSeg": segments["CAPSULE_CAP_SEGMENTS"]}
    if primitive == "torus":
        ratio = descriptor.get("torusTubeRatio")
        tube = 0.45 * float(ratio) if isinstance(ratio, (int, float)) and ratio > 0 else 0.08
        return {
            "op": "torus",
            "tube": r6(tube),
            "seg": segments["TORUS_RADIAL_SEGMENTS"],
            "tubeSeg": segments["TORUS_TUBULAR_SEGMENTS"],
        }
    if primitive == "lathe":
        profile = descriptor.get("latheProfile") if isinstance(descriptor.get("latheProfile"), dict) else {}
        points = profile.get("points") or [[0.3, -0.5], [0.15, 0.0], [0.3, 0.5]]
        seg = profile.get("segments") if isinstance(profile.get("segments"), int) else 24
        return {"op": "lathe", "points": [[r6(x), r6(y)] for x, y in points], "seg": seg}
    if primitive == "extrude":
        profile = descriptor.get("profile2D") if isinstance(descriptor.get("profile2D"), dict) else {}
        points = profile.get("points") or [[-0.3, -0.3], [0.3, -0.3], [0.3, 0.3], [-0.3, 0.3]]
        return {
            "op": "extrude",
            "points": [[r6(x), r6(y)] for x, y in points],
            "depth": r6(_number(profile.get("depth"), 0.1)),
        }
    raise ValueError(f"no Dart construction for primitive {primitive!r}")


def dart_geometry_call(op: dict[str, Any]) -> str:
    """One PartBuilder cascade (without the leading `..`) for a geometry op."""
    kind = op["op"]
    if kind == "box":
        return f"unitBox(color, seg: {op['seg']})"
    if kind == "sphere":
        return f"unitSphere(color, seg: {op['seg']}, rings: {op['rings']})"
    if kind == "cylinder":
        return f"unitCylinder(color, seg: {op['seg']})"
    if kind == "cone":
        return f"unitCone(color, seg: {op['seg']})"
    if kind == "capsule":
        return f"unitCapsule(color, seg: {op['seg']}, capSeg: {op['capSeg']})"
    if kind == "torus":
        return f"unitTorus(color, tube: {dart_double(op['tube'])}, seg: {op['seg']}, tubeSeg: {op['tubeSeg']})"
    if kind == "lathe":
        pts = ", ".join(f"vm.Vector2({dart_double(x)}, {dart_double(y)})" for x, y in op["points"])
        return f"latheY([{pts}], color, seg: {op['seg']})"
    if kind == "extrude":
        pts = ", ".join(f"vm.Vector2({dart_double(x)}, {dart_double(y)})" for x, y in op["points"])
        return f"extrude([{pts}], {dart_double(op['depth'])}, color)"
    if kind == "frustum":
        h = op["halfLength"]
        return (
            f"cylinder(vm.Vector3(0.0, {dart_double(-h)}, 0.0), vm.Vector3(0.0, {dart_double(h)}, 0.0), "
            f"{dart_double(op['baseRadius'])}, {dart_double(op['endRadius'])}, color, seg: {op['seg']})"
        )
    raise ValueError(f"unknown geometry op {kind!r}")


def geometry_call(component: dict[str, Any], segments: dict[str, int]) -> str:
    """One PartBuilder cascade building the component's unit-sized shape."""
    return dart_geometry_call(geometry_op(component, segments))


def build_scene(
    spec: dict[str, Any], pass_id: str, spec_name: str, allow_partial: bool = False
) -> tuple[dict[str, Any] | None, list[str], list[str]]:
    """Return (scene description, unsupported, unapplied) for one build pass.

    The scene description is the single source both outputs render from: `render_dart` turns it
    into a factory, and `--format scene-json` writes it as-is for the runtime's loader. None when
    unsupported features block the pass and `allow_partial` is off.
    """
    components = [c for c in spec.get("componentTree", []) if isinstance(c, dict)]
    included = filter_components_for_pass(spec, components, pass_id)
    segments = segments_for_spec(spec)
    materials = {str(m.get("id")): m for m in spec.get("materials", []) if isinstance(m, dict) and m.get("id")}

    unsupported: list[str] = []
    unapplied: list[str] = []
    built: list[dict[str, Any]] = []
    for component in included:
        cid = str(component.get("id"))
        missing, approximate = classify(component)
        unsupported.extend(f"{cid}: {item}" for item in missing)
        unapplied.extend(f"{cid}: {item}" for item in approximate)
        if not missing:
            built.append(component)
    if spec.get("repetitionSystems"):
        unsupported.append("repetitionSystems (instancing is not ported yet)")
    if unsupported and not allow_partial:
        return None, unsupported, unapplied

    used_materials = sorted({str(c.get("material")) for c in built if c.get("material") in materials})
    known = {str(c.get("id")) for c in built}
    parts: list[dict[str, Any]] = []
    for component in built:
        cid = str(component.get("id"))
        transform = component.get("transform") if isinstance(component.get("transform"), dict) else {}
        parent = component.get("parent")
        material_id = str(component.get("material") or "")
        part: dict[str, Any] = {
            "id": cid,
            "name": str(component.get("name") or cid),
            "role": str(component.get("role") or ""),
            "parent": str(parent) if parent is not None and str(parent) in known else None,
            "kind": str(component.get("primitive") or "box"),
            "position": [r6(v) for v in triple(transform.get("position"))],
            "rotation": [r6(v) for v in triple(transform.get("rotation"))],
            "material": material_id if material_id in used_materials else None,
            "color": argb(material_color(materials.get(material_id))),
        }
        endpoint = attachment_endpoint(component)
        if endpoint is not None:
            part.update(
                kind="attachment frustum",
                position=[r6(v) for v in endpoint["start"]],
                geometry={
                    "op": "frustum",
                    "halfLength": r6(endpoint["length"] / 2),
                    "baseRadius": r6(endpoint["baseRadius"]),
                    "endRadius": r6(endpoint["endRadius"]),
                    "seg": segments["ATTACHMENT_CYLINDER_RADIAL_SEGMENTS"],
                },
                scale=None,
                meshPosition=[r6(v) for v in endpoint["midpoint"]],
                meshRotation=[r6(v) for v in endpoint["quaternion"]],
            )
        else:
            part.update(
                geometry=geometry_op(component, segments),
                scale=[r6(v) for v in scale_triple(component, transform)],
                meshPosition=None,
                meshRotation=None,
            )
        parts.append(part)

    target = str(spec.get("targetName") or spec.get("targetId") or "Object")
    scene = {
        "format": SCENE_FORMAT,
        "target": target,
        "factory": f"create{pascal_case(target)}Model",
        "spec": spec_name,
        "pass": pass_id,
        "omitted": unsupported,
        "unapplied": unapplied,
        "materials": {
            mid: {
                "metallic": r6(material_base_value(materials[mid].get("metalness"), 0.0)),
                "roughness": r6(material_base_value(materials[mid].get("roughness"), 0.6)),
            }
            for mid in used_materials
        },
        "components": parts,
    }
    return scene, unsupported, unapplied


def render_dart(scene: dict[str, Any]) -> str:
    """The Dart factory for a scene description."""
    lines = [
        f"// GENERATED by forge/stage3_build/generate_flutter_scene.py from {scene['spec']}",
        f"// (pass: {scene['pass']}). Carry any hand refinement back into the spec: generated",
        "// code must not be the only copy of a reconstruction decision.",
    ]
    if scene["omitted"]:
        lines.append("//")
        lines.append("// PARTIAL (--allow-partial): omitted, not built at all:")
        lines.extend(f"//   - {item}" for item in scene["omitted"])
    if scene["unapplied"]:
        lines.append("//")
        lines.append("// Built WITHOUT these refinements (shape is approximate there):")
        lines.extend(f"//   - {item}" for item in scene["unapplied"])
    lines += [
        "",
        "import 'package:flutter_scene/scene.dart';",
        "import 'package:img2flutterscene/img2flutterscene.dart';",
        "import 'package:vector_math/vector_math.dart' as vm;",
        "",
        f"/// {scene['target']}, rebuilt in code from its sculpt spec.",
        f"SculptModel {scene['factory']}() {{",
        "  final materials = <String, PhysicallyBasedMaterial>{",
    ]
    for mid, m in scene["materials"].items():
        lines += [
            f"    {dart_string(mid)}: PhysicallyBasedMaterial()",
            f"      ..metallicFactor = {dart_double(m['metallic'])}",
            f"      ..roughnessFactor = {dart_double(m['roughness'])},",
        ]
    lines += [
        "  };",
        f"  final root = Node(name: {dart_string(scene['target'])});",
        "  final nodes = <String, Node>{};",
        "  final components = <String, SculptComponent>{};",
    ]
    if any(part["material"] is None for part in scene["components"]):
        lines.append("  final fallback = PhysicallyBasedMaterial()..roughnessFactor = 0.6;")
    for part in scene["components"]:
        name = part["name"]
        mat_expr = f"materials[{dart_string(part['material'])}]!" if part["material"] is not None else "fallback"
        build = ["    final b = PartBuilder()", f"      ..{dart_geometry_call(part['geometry'])}"]
        if part["scale"] is not None:
            build.append(f"      ..scale(vm.Vector3({', '.join(dart_double(v) for v in part['scale'])}));")
        else:
            build[-1] += ";"
        if part["meshPosition"] is not None:
            build += [
                "    pivot.add(",
                f"      Node(name: {dart_string(name)}, mesh: Mesh(b.build(), {mat_expr}))",
                f"        ..position = vm.Vector3({', '.join(dart_double(v) for v in part['meshPosition'])})",
                f"        ..rotation = vm.Quaternion({', '.join(dart_double(v) for v in part['meshRotation'])}),",
                "    );",
            ]
        else:
            build.append(f"    pivot.add(Node(name: {dart_string(name)}, mesh: Mesh(b.build(), {mat_expr})));")
        parent_id = part["parent"]
        lines += [
            "",
            f"  // {part['id']} — {name} ({part['kind']})",
            "  {",
            f"    final pivot = Node(name: {dart_string(name + '__pivot')})",
            f"      ..position = vm.Vector3({', '.join(dart_double(v) for v in part['position'])})",
            f"      ..rotation = eulerXyz({', '.join(dart_double(v) for v in part['rotation'])});",
            f"    {'nodes[' + dart_string(parent_id) + ']!' if parent_id else 'root'}.add(pivot);",
            f"    nodes[{dart_string(part['id'])}] = pivot;",
            f"    components[{dart_string(part['id'])}] = SculptComponent(",
            f"      id: {dart_string(part['id'])},",
            f"      name: {dart_string(name)},",
            f"      role: {dart_string(part['role'])},",
            *([f"      parent: {dart_string(parent_id)},"] if parent_id else []),
            "    );",
            f"    final color = lin({part['color']});",
            *build,
            "  }",
        ]
    lines += [
        "  return SculptModel(root: root, nodes: nodes, components: components);",
        "}",
        "",
    ]
    return "\n".join(lines)


def generate(spec: dict[str, Any], pass_id: str, spec_name: str, allow_partial: bool = False) -> tuple[str, list[str], list[str]]:
    """Return (dart source, unsupported, unapplied) for one build pass."""
    scene, unsupported, unapplied = build_scene(spec, pass_id, spec_name, allow_partial)
    return ("" if scene is None else render_dart(scene)), unsupported, unapplied


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("spec", type=Path)
    parser.add_argument("--out", type=Path, required=True, help="File to write, e.g. lab/lib/models/chest.dart")
    parser.add_argument(
        "--format",
        choices=("dart", "scene-json"),
        default="dart",
        help="dart: a factory to compile into an app. scene-json: the same model as data, loaded at run "
        "time by the runtime's loadSceneDescription (lab previews, the util app).",
    )
    parser.add_argument("--pass-id", help="Build pass to generate. Defaults to the current unlocked pass.")
    parser.add_argument("--force", action="store_true", help="Overwrite an existing --out file.")
    parser.add_argument(
        "--allow-partial",
        action="store_true",
        help="Omit unsupported components instead of refusing; the header names every omission.",
    )
    parser.add_argument("--allow-nonstrict", action="store_true", help="Test-fixture escape hatch only.")
    parser.add_argument("--blocked-report", type=Path, help="Write the machine-readable BLOCKED report here.")
    args = parser.parse_args(argv)

    spec_path = args.spec.expanduser().resolve()
    spec = load_spec(spec_path)
    errors, warnings, strict_failures = strict_quality_failures(spec)
    if strict_failures and not args.allow_nonstrict:
        emit_blocked(blocked_report(spec_path, strict_failures, warnings, args.pass_id), args.blocked_report)
        return 2
    if args.allow_nonstrict and args.pass_id:
        parser.error("--allow-nonstrict is test-only and cannot be combined with --pass-id")
    if errors:
        parser.error(f"spec validation failed: {'; '.join(errors)}")
    pass_id = args.pass_id or unlocked_pass(spec)
    try:
        assert_pass_unlocked(spec, pass_id)
    except ValueError as exc:
        parser.error(str(exc))
    gaps = pass_specific_gaps(spec, pass_id)
    if gaps:
        parser.error(f"build pass {pass_id!r} needs spec refinement: {'; '.join(gaps)}")
    output = args.out.expanduser().resolve()
    if output.exists() and not args.force:
        parser.error(f"{output} already exists; use --force to overwrite")

    scene, unsupported, unapplied = build_scene(spec, pass_id, spec_path.name, allow_partial=args.allow_partial)
    for item in unapplied:
        print(f"UNAPPLIED {item}", file=sys.stderr)
    if unsupported and not args.allow_partial:
        report = {
            "status": "BLOCKED",
            "phase": "codegen",
            "gate": "flutter-scene-coverage",
            "artifact": str(spec_path),
            "requestedPass": pass_id,
            "cause": unsupported,
            "nextAction": "refine-spec to supported primitives, port the missing construction, "
            "or rerun with --allow-partial for a blockout that names its omissions",
        }
        emit_blocked(report, args.blocked_report)
        return 2
    for item in unsupported:
        print(f"OMITTED {item}", file=sys.stderr)
    output.parent.mkdir(parents=True, exist_ok=True)
    if args.format == "scene-json":
        output.write_text(json.dumps(scene, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(output)
        return 0
    output.write_text(render_dart(scene), encoding="utf-8")
    # Let `dart format` lay the file out (it reads the enclosing package's page width), so the
    # emitted file is format-stable; without dart the file is still valid, just not normalised.
    dart = shutil.which("dart")
    if dart is not None:
        formatted = subprocess.run([dart, "format", str(output)], capture_output=True, text=True)
        if formatted.returncode != 0:
            print(f"WARNING: dart format failed on {output}:\n{formatted.stderr}", file=sys.stderr)
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
