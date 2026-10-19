import contextlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("lab", Path(__file__).resolve().parents[2] / "tools/launch/lab.py")
lab = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lab)


class ProfileSummaryTests(unittest.TestCase):
    def summary(self, passes, **fields):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "profile-t.json").write_text(json.dumps({"profile": "t", "passes": passes, **fields}))
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                lab.profile_summary(Path(directory), "t")
            return output.getvalue()

    def test_categories_follow_most_calls(self):
        # A forward pass with one shadow-named material stays forward.
        mixed = {"Shared_Characters_CHAR_LashesShadow_ST_FOR_vertexMain|f": 1,
                 "Shared_ParticleSystem_VFX_Sparks_STI_FOR_vertexMain|f": 20}
        self.assertEqual(lab.pass_category({"draws": mixed}), "forward")
        self.assertEqual(lab.pass_category({"draws": {"Shared_Base_Base_VT_STI_DEPS_vertexMain|f": 5}}), "shadows")
        self.assertEqual(lab.pass_category({"draws": {"Shared_Base_Base_VT_STI_DEP_vertexMain|f": 5}}), "depth prepass")
        self.assertEqual(lab.pass_category({"dispatches": {"ClusteredLighting_0": 16, "VolumetricFogGather": 1}}),
                         "lighting and decals")
        self.assertEqual(lab.pass_category({"draws": {"BG3MFXViewportVS|DeferredFog_Cubic_PS": 1}}), "fog and clouds")
        self.assertEqual(lab.pass_category({"draws": {"PPDefaultVS|PPTAA_PS": 1}}), "TAA and upscaling")
        self.assertEqual(lab.pass_category({"draws": {"PassPosVS|PPToneMap_LUT": 1}}), "post-processing")

    def test_summary_adds_up_and_finds_repeated_full_target_passes(self):
        target = [{"width": 2560, "height": 1440}]
        passes = [
            {"index": 0, "kind": "render", "gpuMs": 2.0, "draws": {"Shared_Base_Base_VT_STI_DEF_vertexMain|f": 100},
             "viewport": [0, 0, 1280, 1440], "colors": target},
            {"index": 1, "kind": "render", "gpuMs": 0.5, "draws": {"Clear31_VS|Clear31_PS": 1},
             "viewport": [0, 0, 2560, 1440], "colors": target},
            {"index": 2, "kind": "render", "gpuMs": 0.5, "draws": {"Clear31_VS|Clear31_PS": 1},
             "viewport": [0, 0, 2560, 1440], "colors": target},
        ]
        text = self.summary(passes, sumMs=3.0, metal4MsPerFrame=2.2)
        self.assertIn("MetalFX's own queue 2.20 ms", text)
        self.assertRegex(text, r"G-buffer\s+2\.00 ms\s+66\.7%")
        self.assertRegex(text, r"UI and HUD\s+1\.00 ms")
        self.assertIn("1.000 ms x2 Clear31_VS", text)


if __name__ == "__main__":
    unittest.main()
