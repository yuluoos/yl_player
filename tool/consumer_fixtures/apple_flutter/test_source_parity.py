"""Portable checks that the migration gate detects missing or modified copies."""
import json
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[3]
SCRIPT = Path("packages/yl_player_apple/tool/check_source_parity.sh")


class SourceParityTest(unittest.TestCase):
    def test_copy_identity_and_drift(self):
        self.assertTrue((REPO / SCRIPT).is_file(), "source parity gate is missing")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for platform in ("ios", "macos"):
                relative = Path(f"packages/yl_player_{platform}/{platform}/yl_player_{platform}/Sources")
                shutil.copytree(REPO / relative, root / relative)
            (root / SCRIPT).parent.mkdir(parents=True)
            shutil.copyfile(REPO / SCRIPT, root / SCRIPT)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            def run(mode):
                return subprocess.run(["sh", str(root / SCRIPT), mode], cwd=root,
                                      capture_output=True, text=True)
            captured = run("--capture")
            self.assertEqual(captured.returncode, 0, captured.stderr)
            manifest = json.loads((root / SCRIPT.parent / "source-parity.json").read_text())
            rows = [row for row in manifest["sources"] if row["destination"]]
            self.assertEqual(len(rows), 13)
            missing = run("--verify-identical")
            self.assertNotEqual(missing.returncode, 0)
            self.assertIn("missing shared source", missing.stderr)
            for row in rows:
                target = root / row["destination"]
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(root / row["chosen_source"], target)
            verified = run("--verify-identical")
            self.assertEqual(verified.returncode, 0, verified.stderr)
            # A reviewed typed/safety migration keeps immutable legacy provenance,
            # checks its new destination exactly, and cannot conceal later drift.
            migrated = next(row for row in rows if row["name"] == "YlNetworkRequestPolicy.swift")
            migrated_path = root / migrated["destination"]
            original_bytes = migrated_path.read_bytes()
            migrated_path.write_bytes(original_bytes + b"\n// scoped credential context migration\n")
            migrated["task7_migration"] = {
                "ruling": "R18", "reason": "Classified credentials retain sticky origin safety across reader reopen",
                "destination_removed": False,
                "replacements": [{"path": migrated["destination"],
                                  "sha256": hashlib.sha256(migrated_path.read_bytes()).hexdigest()}],
            }
            manifest_file = root / SCRIPT.parent / "source-parity.json"
            manifest_file.write_text(json.dumps(manifest))
            migration = run("--verify-identical")
            self.assertEqual(migration.returncode, 0, migration.stderr)
            migrated_path.write_bytes(migrated_path.read_bytes() + b"// unreviewed drift\n")
            drift = run("--verify-identical")
            self.assertNotEqual(drift.returncode, 0)
            self.assertIn("migrated shared source changed", drift.stderr)
            migrated_path.write_bytes(original_bytes)
            del migrated["task7_migration"]
            manifest_file.write_text(json.dumps(manifest))
            declarations_file = SCRIPT.parent / "source-declarations.json"
            shutil.copyfile(REPO / declarations_file, root / declarations_file)
            declarations = json.loads((root / declarations_file).read_text())["extractions"]
            for declaration in declarations:
                destination = Path(declaration["destination"])
                (root / destination).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(REPO / destination, root / destination)
            self.assertEqual(run("--verify-identical").returncode, 0)
            extracted = root / declarations[0]["destination"]
            extracted.write_bytes(extracted.read_bytes() + b"\n// declaration drift\n")
            drift = run("--verify-identical")
            self.assertNotEqual(drift.returncode, 0)
            self.assertIn("shared declaration file changed", drift.stderr)
            shutil.copyfile(REPO / declarations[0]["destination"], extracted)
            target = root / rows[0]["destination"]
            target.write_bytes(target.read_bytes() + b"\n// drift\n")
            drift = run("--verify-identical")
            self.assertNotEqual(drift.returncode, 0)
            self.assertIn("shared source hash changed", drift.stderr)
            shutil.copyfile(root / rows[0]["chosen_source"], target)
            original = root / rows[0]["chosen_source"]
            original.write_bytes(original.read_bytes() + b"\n// upstream drift\n")
            drift = run("--verify-identical")
            self.assertNotEqual(drift.returncode, 0)
            self.assertIn("baseline source hash changed", drift.stderr)


if __name__ == "__main__":
    unittest.main()
