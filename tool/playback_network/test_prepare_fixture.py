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
