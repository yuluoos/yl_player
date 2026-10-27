import hashlib
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

try:
    import prepare_fixture as prepare
except ModuleNotFoundError:
    prepare = None


class FixtureTests(unittest.TestCase):
    def test_direct_hls_control_preserves_media_and_declared_renditions(self):
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / 'control'
            receipt = prepare.create(output, duration_seconds=120, direct_hls_control=True)
            assets = prepare.load_assets(output)
            self.assertEqual(receipt['assetCount'], 485)
            self.assertEqual(receipt['manifestSha256'],
                             '1be00f4b713ecdcaf00a5744ba344b6973d67db764e3f4aa65bdf613da46ceb6')
            master = assets['direct-master.m3u8'].decode()
            self.assertIn('BANDWIDTH=414000', master)
            self.assertIn('BANDWIDTH=764000', master)
            for rendition, segment_count in [(0, 120), (1, 120), (2, 150)]:
                playlist = assets[f'direct-{rendition}.m3u8'].decode()
                self.assertEqual(playlist.count('#EXT-X-DISCONTINUITY\n'), 29)
                self.assertEqual(playlist.count('#EXTINF:'), segment_count)
                self.assertEqual(playlist.count('#EXT-X-MAP:'), 30)
                self.assertTrue(playlist.endswith('#EXT-X-ENDLIST\n'))
                durations = [float(line.split(':')[1].rstrip(','))
                             for line in playlist.splitlines() if line.startswith('#EXTINF:')]
                self.assertAlmostEqual(sum(durations), 120, places=4)
                for line in playlist.splitlines():
                    if line and not line.startswith('#'):
                        self.assertIn(line, assets)
            self.assertEqual(assets['network-period-29/chunk-1-00001.m4s'],
                             (prepare.SOURCE / 'period1/chunk-1-00001.m4s').read_bytes())
            for name, body in assets.items():
                if name.endswith('.m3u8'):
                    self.assertNotIn(b'http:', body)
                    self.assertNotIn(b'ylhls:', body)

    def test_extended_diagnostic_is_explicit_bounded_and_preserves_frozen_default(self):
        with tempfile.TemporaryDirectory() as work:
            default = prepare.create(Path(work) / 'default')
            self.assertEqual(default['manifestSha256'],
                             'ee00dce275ab3361397bc369a9e3af759efbf6226b5b350d258d0cb34501debb')
            output = Path(work) / 'extended'
            receipt = prepare.create(output, duration_seconds=120)
            self.assertEqual(receipt['durationSeconds'], 120)
            self.assertEqual(receipt['periodCount'], 30)
            root = ET.parse(output / 'manifest.mpd').getroot()
            self.assertEqual(root.get('mediaPresentationDuration'), 'PT120S')
            self.assertEqual(len(root.findall(f'{{{prepare.NS}}}Period')), 30)
            self.assertNotEqual(receipt['manifestSha256'], default['manifestSha256'])
            self.assertEqual((output / 'network-period-29/chunk-1-00001.m4s').read_bytes(),
                             (prepare.SOURCE / 'period1/chunk-1-00001.m4s').read_bytes())
            for invalid in (True, 0, 39, 41, 121, '120', 120.0):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    prepare.create(Path(work) / 'invalid', duration_seconds=invalid)
            self.assertFalse((Path(work) / 'invalid').exists())

    def test_long_programme_preserves_media_addresses_and_has_unique_periods(self):
        self.assertIsNotNone(prepare, 'long owned programme is not implemented')
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / 'fixture'
            prepare.create(output)
            mpd = ET.parse(output / 'manifest.mpd').getroot()
            ns = {'d': 'urn:mpeg:dash:schema:mpd:2011'}
            periods = mpd.findall('d:Period', ns)
            self.assertEqual(mpd.attrib['mediaPresentationDuration'], 'PT40S')
            self.assertEqual(len(periods), 10)
            self.assertEqual(len({p.attrib['id'] for p in periods}), 10)
            for i, period in enumerate(periods):
                self.assertEqual(period.attrib['start'], f'PT{i * 4}S')
                self.assertEqual(period.attrib['duration'], 'PT4S')
                self.assertEqual(period.find('d:BaseURL', ns).text, f'network-period-{i}/')
                self.assertEqual(len(period.findall('d:AdaptationSet/d:Representation', ns)), 3)
            original = prepare.SOURCE
            for path in output.rglob('*.m4s'):
                index = int(path.parent.name.removeprefix('network-period-'))
                self.assertEqual(path.read_bytes(), (original / f'period{index % 2}' / path.name).read_bytes())
            for line in (output / 'SHA256SUMS').read_text().splitlines():
                expected, name = line.split('  ')
                self.assertEqual(hashlib.sha256((output / name).read_bytes()).hexdigest(), expected)
            with self.assertRaises(FileExistsError):
                prepare.create(output)

    def test_missing_variant_only_disappears_after_two_compatible_periods(self):
        with tempfile.TemporaryDirectory() as work:
            output = Path(work) / 'fixture'
            receipt = prepare.create(output, missing_high_after=2)
            ns = {'d': prepare.NS}
            periods = ET.parse(output / 'manifest.mpd').getroot().findall('d:Period', ns)
            highs = [[r for r in p.findall('d:AdaptationSet/d:Representation', ns)
                      if r.get('width') == '640'] for p in periods]
            self.assertEqual([len(v) for v in highs], [1, 1, 0, 0, 0, 0, 0, 0, 0, 0])
            self.assertEqual(receipt['fixedMissingAtMs'], 8000)
            self.assertFalse((output / 'network-period-2/init-1.m4s').exists())
            self.assertTrue((output / 'network-period-2/init-0.m4s').exists())

    def test_regeneration_is_byte_identical(self):
        self.assertIsNotNone(prepare, 'long owned programme is not implemented')
        with tempfile.TemporaryDirectory() as work:
            first, second = Path(work) / 'first', Path(work) / 'second'
            prepare.create(first)
            prepare.create(second)
            self.assertEqual((first / 'SHA256SUMS').read_bytes(),
                             (second / 'SHA256SUMS').read_bytes())


if __name__ == '__main__':
    unittest.main()
