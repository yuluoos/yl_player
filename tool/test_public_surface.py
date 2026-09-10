import tempfile
import unittest
from pathlib import Path

from tool.check_public_surface import validate


class PublicSurfaceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.sandbox = tempfile.TemporaryDirectory()
        self.addCleanup(self.sandbox.cleanup)
        self.root = Path(self.sandbox.name)
        self.spi = self.root / "packages/yl_player_platform_interface/lib"
        self.app = self.root / "packages/yl_player/lib"
        self.spi.mkdir(parents=True)
        self.app.mkdir(parents=True)
        (self.spi / "yl_player_platform_interface.dart").write_text(
            "final class CurrentSpi {}\n", encoding="utf-8"
        )
        (self.app / "yl_player.dart").write_text(
            """export
  'package:yl_player_platform_interface/yl_player_platform_interface.dart'
  show
    CurrentSpi;
""",
            encoding="utf-8",
        )

    def assert_violation(self, expected: str) -> None:
        messages = [violation.message for violation in validate(self.root)]
        self.assertTrue(
            any(expected in message for message in messages),
            f"{expected!r} absent from {messages!r}",
        )

    def test_clean_explicit_surface_passes_and_platform_internals_are_out_of_scope(self) -> None:
        (self.spi / "examples.dart").write_text(
            "// MethodChannel and YlPlayerConfiguration are forbidden examples.\n"
            "const example = \"import 'src/pigeon/example.g.dart';\";\n",
            encoding="utf-8",
        )
        internal = self.root / "packages/yl_player_apple/lib/src"
        internal.mkdir(parents=True)
        (internal / "transport.dart").write_text(
            "import 'pigeon/yl_player_apple.g.dart';\n", encoding="utf-8"
        )
        self.assertEqual(validate(self.root), [])

    def test_legacy_symbol_is_rejected(self) -> None:
        (self.app / "legacy.dart").write_text(
            "typedef OldOptions = YlPlayerConfiguration;\n", encoding="utf-8"
        )
        self.assert_violation("legacy symbol YlPlayerConfiguration")

    def test_platform_channel_symbol_is_rejected(self) -> None:
        (self.spi / "transport.dart").write_text(
            "final channel = MethodChannel('legacy');\n", encoding="utf-8"
        )
        self.assert_violation("Flutter channel symbol MethodChannel")

    def test_broad_platform_interface_exports_are_rejected(self) -> None:
        directives = (
            "export\n"
            "  'package:yl_player_platform_interface/yl_player_platform_interface.dart';\n",
            "export\n"
            "  'package:yl_player_platform_interface/yl_player_platform_interface.dart'\n"
            "  hide InternalThing;\n",
            "export 'fallback.dart'\n"
            "  if (dart.library.io)\n"
            "    'package:yl_player_platform_interface/yl_player_platform_interface.dart';\n",
        )
        for directive in directives:
            with self.subTest(directive=directive):
                (self.app / "yl_player.dart").write_text(
                    directive, encoding="utf-8"
                )
                self.assert_violation("requires an explicit show combinator")

    def test_multiline_generated_pigeon_directives_are_rejected(self) -> None:
        (self.app / "generated_import.dart").write_text(
            "import 'fallback.dart'\n"
            "  if (dart.library.io)\n"
            "    '../generated/yl_player_android.g.dart';\n",
            encoding="utf-8",
        )
        (self.spi / "generated_export.dart").write_text(
            "export\n  'package:yl_player_platform_interface/src/pigeon/api.g.dart'\n"
            "  show PublicDto;\n",
            encoding="utf-8",
        )
        messages = [violation.message for violation in validate(self.root)]
        self.assertEqual(
            sum("generated Pigeon library" in message for message in messages), 2
        )


if __name__ == "__main__":
    unittest.main()
