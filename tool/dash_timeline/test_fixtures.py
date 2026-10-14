import base64
import hashlib
import json
from fractions import Fraction
import struct
import xml.etree.ElementTree as ET
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
MEDIA = ROOT / 'packages/yl_player/example/assets/test_media/dash_timeline'

class TimelineFixturesTest(unittest.TestCase):
    def test_native_bundle_contains_original_media_bytes(self):
        expected = {str(p.relative_to(MEDIA)): p.read_bytes() for p in MEDIA.rglob('*')
                    if p.suffix in ('.mpd', '.m4s')}
        for folder in ('tool/consumer_fixtures/apple_flutter/Resources',
                       'packages/yl_player/example/ios/RunnerTests',
                       'packages/yl_player/example/macos/RunnerTests'):
            encoded = json.loads((ROOT / folder / 'p01-program-fixtures.json').read_text())
            self.assertEqual({k: base64.b64decode(v) for k, v in encoded.items()}, expected)

    def test_seven_dimensions_have_raw_media_and_rational_expected_clocks(self):
        rows = json.loads((MEDIA/'matrix.json').read_text())
        self.assertEqual({r['id'] for r in rows}, {'independent-pto', 'clip-end', 'gap', 'overlap', 'unknown-middle', 'multiple-base', 'fractional-microsecond'})
        for row in rows:
            self.assertTrue((MEDIA/row['mpd']).is_file())
            self.assertTrue(row['expected'])
            self.assertEqual(row['productionAcceptance'], 'rejected')
        self.assertTrue((MEDIA/'reference.vtt').is_file())
    def test_large_clock_is_exactly_equivalent_to_original_manifest(self):
        ns = {'d': 'urn:mpeg:dash:schema:mpd:2011'}
        original = ET.parse(MEDIA/'manifest.mpd').findall('.//d:SegmentTemplate', ns)
        large = ET.parse(MEDIA/'large-exact.mpd').findall('.//d:SegmentTemplate', ns)
        self.assertEqual(len(original), 4)
        self.assertEqual(len(large), 4)
        for a, b in zip(original, large):
            scale_a, scale_b = int(a.attrib['timescale']), int(b.attrib['timescale'])
            self.assertEqual(scale_b, scale_a * 10**9)
            sa, sb = a.findall('.//d:S', ns), b.findall('.//d:S', ns)
            self.assertEqual(len(sa), len(sb))
            for x, y in zip(sa, sb):
                for key in ['t', 'd']:
                    self.assertEqual(Fraction(int(x.attrib[key]), scale_a), Fraction(int(y.attrib[key]), scale_b))

    def test_independent_offsets_preserve_encoded_payloads(self):
        def boxes(data, offset=0, end=None):
            end = len(data) if end is None else end
            while offset < end:
                size, kind = struct.unpack_from('>I4s', data, offset)
                self.assertGreaterEqual(size, 8)
                self.assertLessEqual(offset + size, end)
                if kind in (b'moof', b'traf'):
                    yield from boxes(data, offset+8, offset+size)
                else:
                    yield kind, data[offset+8:offset+size]
                offset += size
        for original in (MEDIA/'period0').glob('*.m4s'):
            shifted = MEDIA/'independent'/original.name
            if original.name.startswith('init'):
                self.assertEqual(original.read_bytes(), shifted.read_bytes())
                continue
            a, b = list(boxes(original.read_bytes())), list(boxes(shifted.read_bytes()))
            self.assertEqual(len(a), len(b))
            delta = 10*12288 if '-0-' in original.name else 20*48000
            clocks = 0
            for (kind, x), (other_kind, y) in zip(a, b):
                self.assertEqual(kind, other_kind)
                if kind in (b'tfdt', b'sidx'):
                    fmt = '>I' if x[0] == 0 else '>Q'
                    pos = 4 if kind == b'tfdt' else 12
                    self.assertEqual(struct.unpack_from(fmt, y, pos)[0] - struct.unpack_from(fmt, x, pos)[0], delta)
                    clocks += 1
                else:
                    self.assertEqual(x, y)
            self.assertEqual(clocks, 2)

    def test_original_media_and_generated_manifests_are_pinned(self):
        lines = (MEDIA/'SHA256SUMS').read_text().splitlines()
        self.assertGreater(len(lines), 25)
        for line in lines:
            sha, file = line.split('  ')
            self.assertEqual(hashlib.sha256((MEDIA/file).read_bytes()).hexdigest(), sha)
        for period in [0, 1]:
            for track in [0, 1]:
                self.assertTrue((MEDIA/f'period{period}/init-{track}.m4s').is_file())

if __name__ == '__main__': unittest.main()
