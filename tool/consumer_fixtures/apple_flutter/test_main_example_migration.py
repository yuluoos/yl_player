"""Checks the endorsed example suite and immutable pre-endorsement provenance."""

import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[3]
GATE = ROOT / "tool/consumer_fixtures/apple_flutter/main_example_tests.py"


def load_gate():
    spec = importlib.util.spec_from_file_location("main_example_tests", GATE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class MainExampleMigrationTests(unittest.TestCase):
    def test_current_example_matches_accepted_shared_fixtures(self):
        load_gate().verify_current_targets(ROOT)

    def test_historical_sources_match_the_pinned_pre_endorsement_commit(self):
        load_gate().verify_historical_sources(ROOT)

    def test_retired_resource_source_uses_pinned_pre_endorsement_blob(self):
        module = load_gate()
        manifest = "resources-manifest.json"
        rows = json.loads((GATE.parent / manifest).read_text())
        row = next(
            row
            for row in rows
            if row["source"].endswith("RunnerTests/Fixtures/hevc_aac.mkv")
        )
        self.assertFalse((ROOT / row["source"]).exists())
        self.assertEqual(
            module.source_bytes(ROOT, manifest, row),
            module.git_blob(ROOT, module.PINNED_REVISION, row["source"]),
        )

    def test_missing_history_fails_with_an_explicit_fetch_prerequisite(self):
        module = load_gate()
        with self.assertRaisesRegex(
            RuntimeError,
            "missing pinned historical revision.*git fetch --no-tags --depth=1",
        ):
            module.require_revision(ROOT, "0" * 40)


if __name__ == "__main__":
    unittest.main()
