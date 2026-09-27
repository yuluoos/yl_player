"""Fixture layout checks independent of the Swift parser under test."""
import hashlib
from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / 'tool/consumer_fixtures/apple_flutter/Resources'

class FixtureTests(unittest.TestCase):
    def test_owned_v0_v1_indexes_address_original_fragment_bytes(self):
        for version in (0, 1):
            path = FIXTURES / f'dash-sidx-v{version}.mp4'
            self.assertTrue(path.exists(), 'owned sidx fixture not generated')
            data = path.read_bytes()
            origin = ROOT/'packages/yl_player/example/assets/test_media/dash/period0'
            init = (origin/'init-0.m4s').read_bytes()
            self.assertEqual(data[:len(init)], init)
            size, kind = struct.unpack_from('>I4s', data, len(init))
            self.assertEqual(kind, b'sidx')
            self.assertEqual(size, 80 if version == 0 else 88)
            self.assertEqual(data[len(init)+8], version)
            offset = len(init) + size
            for number in range(1,5):
                fragment = (origin/f'chunk-0-{number:05}.m4s').read_bytes()
                self.assertEqual(data[offset:offset+len(fragment)], fragment)
                offset += len(fragment)
            self.assertEqual(offset, len(data))
    def test_fixture_hashes_are_recorded(self):
        manifest = ROOT/'tool/dash_sidx/SHA256SUMS'
        self.assertTrue(manifest.exists(), 'owned hashes not recorded')
        for row in manifest.read_text().splitlines():
            sha, name = row.split('  ')
            self.assertEqual(hashlib.sha256((ROOT/name).read_bytes()).hexdigest(),sha)

if __name__ == '__main__': unittest.main()
