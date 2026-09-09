"""R16 immutable origin proof survives a checkout with no live Apple sources."""
import copy
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch
from historical_origins import FIXTURE, origin_tree, verify_historical

class HistoricalOriginsTests(unittest.TestCase):
    def test_no_git_no_live_sources_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'fixture'
            shutil.copytree(FIXTURE, fixture)
            with patch.dict(os.environ, {'PATH': ''}), patch('subprocess.run', side_effect=AssertionError('no subprocess')):
                verify_historical(fixture)
            self.assertFalse((Path(directory) / 'packages').exists())

    def test_missing_tampered_archive_and_metadata_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            shutil.copytree(FIXTURE, fixture, dirs_exist_ok=True)
            metadata = fixture / 'manifest.json'
            original = metadata.read_bytes()
            meta = json.loads(original)
            archive = fixture / meta['archive']; raw = archive.read_bytes()
            archive.unlink()
            with self.assertRaises((OSError, ValueError)): verify_historical(fixture)
            for corrupt in [b'broken', raw[:-1], raw + b'tampered']:
                archive.write_bytes(corrupt)
                with self.assertRaises(ValueError): verify_historical(fixture)
            archive.write_bytes(raw)
            for change in [lambda m: m['entries'].pop(), lambda m: m['entries'][0].update(sha256='0' * 64),
                           lambda m: m.update(origin_revision='0' * 40)]:
                altered = copy.deepcopy(meta); change(altered)
                metadata.write_text(json.dumps(altered))
                with self.assertRaises(ValueError): verify_historical(fixture)

    def test_exact_origin_inventory(self):
        with origin_tree() as root:
            self.assertEqual(len([p for p in root.rglob('*') if p.is_file()]), 88)

if __name__ == '__main__': unittest.main()
