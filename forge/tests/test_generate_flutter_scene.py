"""Contracts for the flutter_scene emitter (forge/stage3_build/generate_flutter_scene.py).

The emitter shares the three.js generator's gates, so these tests pin what is
specific to the Dart target: fail-closed coverage, pivot/parent emission,
dimension baking in parity with `scale_triple`, and -- when Flutter is on the
PATH -- that the emitted Dart actually compiles against the runtime package.
Set IMG2FLUTTERSCENE_REQUIRE_FLUTTER=1 to turn a missing Flutter into a failure.
"""

from __future__ import annotations

import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / "forge" / "stage3_build"), str(ROOT / "forge" / "_shared"), str(ROOT / "forge" / "stage2_spec")]

import generate_flutter_scene as gfs  # noqa: E402
from generate_threejs_factory import scale_triple  # noqa: E402

SCRIPT = ROOT / "forge" / "stage3_build" / "generate_flutter_scene.py"
SAMPLE = ROOT / "lab" / "specs" / "sample_hard_case.json"
FIXTURES = ROOT / "forge" / "tests" / "fixtures"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def run(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True)


class CliGateTests(unittest.TestCase):
    def test_strict_quality_failure_blocks_before_any_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "m.dart"
            result = run(str(FIXTURES / "subdivision_cage.json"), "--out", str(out))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn('"gate": "strict-quality"', result.stderr)
            self.assertFalse(out.exists())

    def test_unsupported_features_block_without_allow_partial(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "m.dart"
            report = Path(tmp) / "blocked.json"
            result = run(str(SAMPLE), "--out", str(out), "--blocked-report", str(report))
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertFalse(out.exists())
            blocked = load(report)
            self.assertEqual(blocked["gate"], "flutter-scene-coverage")
            self.assertIn("repetitionSystems (instancing is not ported yet)", blocked["cause"])

    def test_allow_partial_writes_and_names_every_omission(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "m.dart"
            result = run(str(SAMPLE), "--out", str(out), "--allow-partial")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("OMITTED repetitionSystems", result.stderr)
            source = out.read_text(encoding="utf-8")
            self.assertIn("// PARTIAL (--allow-partial): omitted, not built at all:", source)
            self.assertIn("//   - repetitionSystems", source)

    def test_refuses_to_overwrite_without_force(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "m.dart"
            out.write_text("keep", encoding="utf-8")
            result = run(str(SAMPLE), "--out", str(out), "--allow-partial")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(out.read_text(encoding="utf-8"), "keep")


class EmissionTests(unittest.TestCase):
    def setUp(self):
        self.spec = load(SAMPLE)

    def test_blockout_emits_only_macro_components(self):
        source, _, _ = gfs.generate(self.spec, "blockout", "s.json", allow_partial=True)
        self.assertEqual(re.findall(r"nodes\['([^']+)'\] = pivot;", source), ["root", "lid"])

    def test_later_pass_emits_every_component_parent_first(self):
        source, unsupported, _ = gfs.generate(self.spec, "form-refinement", "s.json", allow_partial=True)
        self.assertEqual(unsupported, ["repetitionSystems (instancing is not ported yet)"])
        emitted = re.findall(r"nodes\['([^']+)'\] = pivot;", source)
        self.assertEqual(len(emitted), len(self.spec["componentTree"]))
        parents = {c["id"]: c.get("parent") for c in self.spec["componentTree"]}
        for cid in emitted:
            parent = parents[cid]
            if parent:
                self.assertLess(emitted.index(parent), emitted.index(cid), f"{parent} must precede {cid}")
        # A child attaches to its parent's pivot, a root component to the model root.
        self.assertIn("nodes['haspLoop']!.add(pivot);\n    nodes['padlock'] = pivot;", source)
        self.assertIn("root.add(pivot);\n    nodes['root'] = pivot;", source)

    def test_dimensions_are_baked_with_scale_triple_parity(self):
        source, _, _ = gfs.generate(self.spec, "form-refinement", "s.json", allow_partial=True)
        for component in self.spec["componentTree"]:
            if gfs.attachment_endpoint(component) is not None:
                continue  # sized by its endpoints, never re-scaled (see the endpoint test)
            size = scale_triple(component, component.get("transform", {}))
            expected = f"..scale(vm.Vector3({', '.join(gfs.dart_double(v) for v in size)}))"
            block = source.split(f"nodes['{component['id']}'] = pivot;", 1)[1].split("\n  }\n", 1)[0]
            self.assertIn(expected, block, component["id"])

    def test_an_explicit_transform_scale_still_overrides_dimensions(self):
        """Same rule as the three.js generator: `transform.scale` wins over `dimensions`."""
        spec = copy.deepcopy(self.spec)
        spec["componentTree"][0]["transform"]["scale"] = [2, 3, 4]
        source, _, _ = gfs.generate(spec, "blockout", "s.json", allow_partial=True)
        self.assertIn("..scale(vm.Vector3(2.0, 3.0, 4.0))", source)

    def test_attachment_parts_span_their_endpoints_like_three(self):
        """Pivot at localStart, frustum of the segment's length, mesh at the midpoint turned +Y -> dir."""
        fastener = next(c for c in self.spec["componentTree"] if c["id"] == "lidFastener")
        endpoint = gfs.attachment_endpoint(fastener)
        self.assertIsNotNone(endpoint)
        self.assertEqual(endpoint["start"], [-0.39, 0.0, 0.0])
        self.assertAlmostEqual(endpoint["length"], 0.78)
        self.assertEqual(endpoint["midpoint"], [0.39, 0.0, 0.0])
        self.assertEqual((endpoint["baseRadius"], endpoint["endRadius"]), (0.06, 0.06 * 0.55))
        # +Y onto +X is a -90 degree turn about Z.
        h = 0.5 ** 0.5
        for got, want in zip(endpoint["quaternion"], [0.0, 0.0, -h, h]):
            self.assertAlmostEqual(got, want)
        source, _, _ = gfs.generate(self.spec, "form-refinement", "s.json", allow_partial=True)
        block = source.split("nodes['lidFastener'] = pivot;", 1)[1].split("\n  }\n", 1)[0]
        self.assertIn("..cylinder(vm.Vector3(0.0, -0.39, 0.0), vm.Vector3(0.0, 0.39, 0.0), 0.06, 0.033, color", block)
        self.assertIn("..position = vm.Vector3(0.39, 0.0, 0.0)", block)
        self.assertNotIn("..scale(", block)
        # Opposite direction: three's fallback axis.
        down = copy.deepcopy(fastener)
        down["attachment"]["localStart"], down["attachment"]["localEnd"] = [0, 0, 0], [0, -1, 0]
        self.assertEqual(gfs.attachment_endpoint(down)["quaternion"], [0.0, 0.0, 1.0, 0.0])
        # A degenerate segment falls back to the component's own primitive and transform.
        flat = copy.deepcopy(fastener)
        flat["attachment"]["localEnd"] = flat["attachment"]["localStart"]
        self.assertIsNone(gfs.attachment_endpoint(flat))

    def test_rotation_and_position_go_on_the_pivot(self):
        source, _, _ = gfs.generate(self.spec, "form-refinement", "s.json", allow_partial=True)
        ridge = next(c for c in self.spec["componentTree"] if c["id"] == "lidRidge")
        name = ridge.get("name") or "lidRidge"
        block = source.split(f"final pivot = Node(name: '{name}__pivot')", 1)[1].split("\n  }\n", 1)[0]
        self.assertIn("..rotation = eulerXyz(0.0, 0.0, 1.5708)", block)
        self.assertIn("..position = vm.Vector3(0.0, 0.37, 0.0)", block)

    def test_materials_are_shared_by_id_with_pbr_scalars(self):
        source, _, _ = gfs.generate(self.spec, "form-refinement", "s.json", allow_partial=True)
        self.assertEqual(source.count("'shellMatte': PhysicallyBasedMaterial()"), 1)
        self.assertIn("..roughnessFactor = 0.62", source)
        self.assertIn("lin(0xFF212327)", source)
        self.assertNotIn("final fallback", source, "fallback material must only be emitted when used")

    def test_unsupported_geometry_is_named_never_substituted(self):
        spec = copy.deepcopy(self.spec)
        lid = spec["componentTree"][1]
        lid["primitive"] = "curve-sweep"
        lid.pop("attachment", None)  # with endpoints it would be a frustum, as in three
        spec["componentTree"][0]["geometryDescriptor"]["sdf"] = {"op": "sphere"}
        _, unsupported, _ = gfs.generate(spec, "blockout", "s.json")
        self.assertIn("lid: primitive 'curve-sweep'", unsupported)
        self.assertIn("root: implicit SDF surface (geometryDescriptor.sdf)", unsupported)
        source, _, _ = gfs.generate(spec, "blockout", "s.json", allow_partial=True)
        # Omitted outright -- never quietly rebuilt as a box.
        self.assertNotIn("nodes['lid'] = pivot;", source)
        self.assertNotIn("nodes['root'] = pivot;", source)
        self.assertNotIn("unitBox", source)

    def test_unapplied_refinements_are_listed_in_the_header(self):
        _, _, unapplied = gfs.generate(self.spec, "blockout", "s.json", allow_partial=True)
        self.assertIn("root: geometryDescriptor.deformationStack", unapplied)
        self.assertIn("root: geometryDescriptor.edgeTreatment", unapplied)

    def test_value_formatting(self):
        self.assertEqual(gfs.dart_double(1), "1.0")
        self.assertEqual(gfs.dart_double(0.24000000000000002), "0.24")
        self.assertEqual(gfs.dart_double(-0.0000001), "-0.0")
        self.assertEqual(gfs.argb("#abc"), "0xFFAABBCC")
        self.assertEqual(gfs.argb("not-a-colour"), "0xFF8A7A5F")
        self.assertEqual(gfs.dart_string("it's $x"), "'it\\'s \\$x'")


class SceneJsonTests(unittest.TestCase):
    """`--format scene-json`: the same model as data, for the runtime's loader."""

    def test_runtime_fixture_is_current(self):
        """runtime/test/fixtures/sample_hard_case.scene.json backs the Dart loader tests."""
        scene, _, _ = gfs.build_scene(load(SAMPLE), "form-refinement", "sample_hard_case.json", allow_partial=True)
        fixture = load(ROOT / "runtime" / "test" / "fixtures" / "sample_hard_case.scene.json")
        self.assertEqual(
            fixture,
            json.loads(json.dumps(scene)),
            "regenerate the fixture with build_scene(..., 'form-refinement', 'sample_hard_case.json', allow_partial=True)",
        )

    def test_json_and_dart_describe_the_same_parts(self):
        scene, _, _ = gfs.build_scene(load(SAMPLE), "form-refinement", "s.json", allow_partial=True)
        source = gfs.render_dart(scene)
        self.assertEqual(scene["format"], gfs.SCENE_FORMAT)
        self.assertEqual(
            [p["id"] for p in scene["components"]],
            re.findall(r"nodes\['([^']+)'\] = pivot;", source),
        )
        for part in scene["components"]:
            self.assertIn(gfs.dart_geometry_call(part["geometry"]), source, part["id"])

    def test_cli_writes_json_through_the_same_gates(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "m.scene.json"
            blocked = run(str(SAMPLE), "--out", str(out), "--format", "scene-json")
            self.assertEqual(blocked.returncode, 2)
            self.assertFalse(out.exists())
            result = run(str(SAMPLE), "--out", str(out), "--format", "scene-json", "--allow-partial")
            self.assertEqual(result.returncode, 0, result.stderr)
            scene = load(out)
            self.assertEqual(scene["pass"], "blockout")
            self.assertEqual([p["id"] for p in scene["components"]], ["root", "lid"])
            self.assertIn("repetitionSystems (instancing is not ported yet)", scene["omitted"])


class DartCompileGateTests(unittest.TestCase):
    """The emitted Dart must compile against runtime/ -- structural tests alone do not prove it."""

    def test_full_pass_output_passes_flutter_analyze(self):
        flutter = shutil.which("flutter")
        if flutter is None:
            if os.environ.get("IMG2FLUTTERSCENE_REQUIRE_FLUTTER") == "1":
                self.fail("flutter is not on PATH and IMG2FLUTTERSCENE_REQUIRE_FLUTTER=1")
            self.skipTest("flutter not on PATH; the emitted Dart was NOT compiled")
        source, _, _ = gfs.generate(load(SAMPLE), "form-refinement", "s.json", allow_partial=True)
        with tempfile.TemporaryDirectory() as tmp:
            pkg = Path(tmp)
            (pkg / "lib").mkdir()
            (pkg / "pubspec.yaml").write_text(
                "name: emit_gate\npublish_to: none\nenvironment:\n  sdk: ^3.13.5\n"
                "dependencies:\n  flutter:\n    sdk: flutter\n  flutter_scene: ^0.24.3\n  vector_math: ^2.4.3\n"
                f"  img2flutterscene:\n    path: {ROOT / 'runtime'}\n",
                encoding="utf-8",
            )
            (pkg / "lib" / "model.dart").write_text(source, encoding="utf-8")
            get = subprocess.run([flutter, "pub", "get", "--offline"], cwd=pkg, capture_output=True, text=True)
            self.assertEqual(get.returncode, 0, get.stdout + get.stderr)
            result = subprocess.run([flutter, "analyze", "--no-pub", "lib"], cwd=pkg, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("No issues found", result.stdout)


if __name__ == "__main__":
    unittest.main()
