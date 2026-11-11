"""Relocation must preserve identity; changed tools or SDKs must not."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'packages/yl_player_media_core/tool/apple_ffmpeg/toolchain_identity.py'
SPEC = importlib.util.spec_from_file_location('ffmpeg_toolchain_identity', SOURCE)
identity = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(identity)


class ToolchainIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def installation(self, name):
        developer = self.root / name / 'Contents/Developer'
        for tool in ('clang', 'ld', 'ar', 'ranlib'):
            p = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin' / tool
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(('fixed ' + tool).encode())
        for sdk in ('iphoneos', 'iphonesimulator', 'macosx'):
            p = developer / 'SDKs' / sdk / 'SDKSettings.json'
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text('{"Version":"27.2"}')
        return developer

    def capture(self, developer, versions=None, foreign_tool=None):
        versions = versions or {}

        def run(*args):
            if args == ('xcodebuild', '-version'):
                return versions.get('xcode', 'Xcode 27.2\nBuild version 27B52')
            if args[0] in ('meson', 'ninja'):
                return versions.get(args[0], 'pinned-' + args[0])
            if args[:2] == ('xcrun', 'clang'):
                self.assertEqual(args[2:], ('--target=arm64-apple-macos12.0', '--version'))
                return 'Apple clang version pinned\nTarget: arm64-apple-macos12.0\nInstalledDir: ' + str(developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin')
            if args[:2] == ('xcrun', '--find'):
                return str(foreign_tool or developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin' / args[2])
            self.assertEqual(args[:2], ('xcrun', '--sdk'))
            sdk, option = args[2:]
            if option == '--show-sdk-path':
                return str(developer / 'SDKs' / sdk)
            return versions.get(sdk + option, '27.2' if option == '--show-sdk-version' else 'pinned-build')

        with patch.dict(os.environ, DEVELOPER_DIR=str(developer)), patch.object(identity, 'run', side_effect=run):
            return identity.capture()

    def test_different_install_locations_and_aliases_have_same_identity(self):
        first = self.installation('Xcode.app')
        second = self.installation('Xcode_27.2.app')
        alias = self.root / 'alias'
        alias.symlink_to(second, target_is_directory=True)
        self.assertEqual(self.capture(first), self.capture(second))
        self.assertEqual(self.capture(first), self.capture(alias))

    def test_each_tool_binary_change_changes_identity(self):
        developer = self.installation('Xcode.app')
        before = self.capture(developer)
        for tool in ('clang', 'ld', 'ar', 'ranlib'):
            with self.subTest(tool=tool):
                p = developer / 'Toolchains/XcodeDefault.xctoolchain/usr/bin' / tool
                original = p.read_bytes()
                p.write_bytes(original + b'changed')
                self.assertNotEqual(before[tool + '_sha256'], self.capture(developer)[tool + '_sha256'])
                p.write_bytes(original)

    def test_each_sdk_settings_change_changes_identity(self):
        developer = self.installation('Xcode.app')
        before = self.capture(developer)
        for sdk in ('iphoneos', 'iphonesimulator', 'macosx'):
            with self.subTest(sdk=sdk):
                p = developer / 'SDKs' / sdk / 'SDKSettings.json'
                original = p.read_bytes()
                p.write_bytes(original + b' ')
                self.assertNotEqual(before[sdk], self.capture(developer)[sdk])
                p.write_bytes(original)

    def test_versions_and_sdk_builds_remain_significant(self):
        developer = self.installation('Xcode.app')
        before = self.capture(developer)
        for key in ('xcode', 'meson', 'ninja', 'iphoneos--show-sdk-build-version', 'macosx--show-sdk-version'):
            with self.subTest(key=key):
                self.assertNotEqual(before, self.capture(developer, {key: 'different'}))

    def test_tool_outside_selected_xcode_is_rejected(self):
        developer = self.installation('Xcode.app')
        other = self.root / 'external-clang'
        other.write_bytes(b'compiler')
        with self.assertRaises(ValueError):
            self.capture(developer, foreign_tool=other)


if __name__ == '__main__':
    unittest.main()
