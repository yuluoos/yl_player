import os
from pathlib import Path
import sys
import unittest


ROOT = Path(__file__).resolve().parents[3]
os.environ.setdefault("YL_REPO_ROOT", str(ROOT))
os.environ.setdefault("YL_FLUTTER", "unused-for-unit-tests")
sys.path.insert(0, str(Path(__file__).resolve().parent))

from consumers import require_architectures, require_minimum_os, require_symbols


class LinkInspectionTests(unittest.TestCase):
    def test_requires_every_requested_architecture(self):
        require_architectures("arm64 x86_64\n", {"arm64", "x86_64"}, "consumer")

        with self.assertRaisesRegex(RuntimeError, "consumer is missing architectures: x86_64"):
            require_architectures("arm64\n", {"arm64", "x86_64"}, "consumer")

    def test_requires_public_plugin_and_concrete_bridge_symbols(self):
        symbols = """000 T type metadata accessor for yl_player_apple.YlPlayerApplePlugin
000 T _ylf_build_configuration
"""
        require_symbols(symbols, "consumer")

        with self.assertRaisesRegex(RuntimeError, "YlPlayerApplePlugin"):
            require_symbols("000 T _ylf_build_configuration\n", "consumer")
        with self.assertRaisesRegex(RuntimeError, "_ylf_build_configuration"):
            require_symbols("000 T type metadata accessor for yl_player_apple.YlPlayerApplePlugin\n", "consumer")

    def test_requires_every_minos_record_to_match_the_floor(self):
        load_commands = """Load command 8
      cmd LC_BUILD_VERSION
 platform MACOS
    minos 12.0
      sdk 26.5
Load command 8
      cmd LC_BUILD_VERSION
 platform MACOS
    minos 12.0
      sdk 26.5
"""
        require_minimum_os(load_commands, "12.0", "consumer")

        with self.assertRaisesRegex(RuntimeError, "minimum OS values"):
            require_minimum_os(load_commands.replace("12.0", "13.0", 1), "12.0", "consumer")


if __name__ == "__main__":
    unittest.main(verbosity=2)
