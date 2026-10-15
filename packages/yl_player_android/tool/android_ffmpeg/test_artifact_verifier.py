"""Mutations of temporary artifact copies must never be accepted or repaired."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest

TOOL = Path(__file__).with_name("verify_artifact.py")
INSTALLED = TOOL.parents[2] / "android/src/main/jniLibs"


class ArtifactVerifierTest(unittest.TestCase):
    def check_rejected(self, root):
        manifest = (root / "bridge-artifact.json").read_bytes()
        result = subprocess.run([sys.executable, "-B", str(TOOL), "--root", str(root)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("identity mismatch", result.stderr)
        self.assertEqual((root / "bridge-artifact.json").read_bytes(), manifest)

    def test_changed_binary_cannot_pass_or_rewrite_manifest(self):
        with tempfile.TemporaryDirectory(prefix="yl-p03-artifact-negative-") as directory:
            root = Path(directory) / "artifact"
            shutil.copytree(INSTALLED, root)
            binary = root / "arm64-v8a/libyl_player_ffmpeg.so"
            data = bytearray(binary.read_bytes()); data[len(data) // 2] ^= 1; binary.write_bytes(data)
            self.check_rejected(root)

    def test_stale_source_identity_is_not_repaired(self):
        with tempfile.TemporaryDirectory(prefix="yl-p03-artifact-negative-") as directory:
            root = Path(directory) / "artifact"
            shutil.copytree(INSTALLED, root)
            manifest = root / "bridge-artifact.json"
            value = json.loads(manifest.read_text())
            value["inputs"]["android/src/main/cpp/YlSoftwareVideoBudget.inc"] = "0" * 64
            manifest.write_text(json.dumps(value))
            self.check_rejected(root)

    def test_installed_evidence_cannot_be_regenerated_by_record_mode(self):
        before = (INSTALLED / "bridge-artifact.json").read_bytes()
        result = subprocess.run([sys.executable, "-B", str(TOOL), "--record-candidate", str(INSTALLED)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("outside the installed directory", result.stderr)
        self.assertEqual(before, (INSTALLED / "bridge-artifact.json").read_bytes())


if __name__ == "__main__":
    unittest.main()
