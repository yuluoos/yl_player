"""R14: frozen proof is immutable and independent of the current source checkout."""
import copy
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest.mock import patch
from historical_migration import frozen_tree, verify_historical

FIXTURE = Path(__file__).with_name('historical_migration')

class HistoricalMigrationTests(unittest.TestCase):
    def test_checkout_only_without_current_sources_git_or_path(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'fixture'
            shutil.copytree(FIXTURE, fixture)
            with patch.dict(os.environ, {'PATH': ''}), patch('subprocess.check_output', side_effect=AssertionError('no git')):
                self.assertEqual(verify_historical(fixture), [])
            # No live production or legacy tree exists in this isolated checkout.
            self.assertFalse((Path(directory) / 'packages').exists())

    def test_missing_corrupt_and_changed_archive_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            shutil.copytree(FIXTURE, fixture, dirs_exist_ok=True)
            meta = json.loads((fixture / 'manifest.json').read_text())
            archive = fixture / meta['archive']
            original = archive.read_bytes()
            archive.unlink()
            with self.assertRaises((ValueError, OSError)): verify_historical(fixture)
            for raw in [b'corrupt', original[:-1], original + b'tampered']:
                archive.write_bytes(raw)
                with self.assertRaises(ValueError): verify_historical(fixture)

    def test_metadata_inventory_and_path_tampering_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            shutil.copytree(FIXTURE, fixture, dirs_exist_ok=True)
            path = fixture / 'manifest.json'
            original = json.loads(path.read_text())
            for mutate in [lambda m: m['entries'].pop(),
                           lambda m: m['entries'][0].update(path='../outside'),
                           lambda m: m['entries'][0].update(sha256='0' * 64),
                           lambda m: m.update(origin_revision='0' * 40)]:
                changed = copy.deepcopy(original); mutate(changed)
                path.write_text(json.dumps(changed))
                with self.assertRaises(ValueError): verify_historical(fixture)

    def test_archive_entry_validation_rejects_missing_tampered_duplicate_and_nonregular(self):
        # Re-sign only the test envelope to exercise entry checks independently
        # of the immutable production envelope pins.
        original_meta = json.loads((FIXTURE / 'manifest.json').read_text())
        original_archive = (FIXTURE / original_meta['archive']).read_bytes()
        with tarfile.open(fileobj=io.BytesIO(original_archive), mode='r:gz') as archive:
            entries = [(member, archive.extractfile(member).read()) for member in archive]
        for mutation in ['missing', 'content', 'duplicate', 'symlink', 'traversal']:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as directory:
                selected = list(entries)
                if mutation == 'missing': selected.pop()
                if mutation == 'duplicate': selected.append(entries[0])
                output = io.BytesIO()
                with tarfile.open(fileobj=output, mode='w:gz') as archive:
                    for index, (member, data) in enumerate(selected):
                        member = copy.copy(member)
                        if index == 0:
                            if mutation == 'content': data = b'X' + data[1:]
                            if mutation == 'symlink': member.type = tarfile.SYMTYPE; member.linkname = '/tmp/outside'
                            if mutation == 'traversal': member.name = '../outside'
                        archive.addfile(member, io.BytesIO(data))
                raw = output.getvalue()
                meta = copy.deepcopy(original_meta)
                digest = hashlib.sha256(raw).hexdigest()
                meta.update(archive=digest + '.tar.gz', archive_sha256=digest, archive_size=len(raw))
                fixture = Path(directory)
                (fixture / meta['archive']).write_bytes(raw)
                metadata = json.dumps(meta).encode()
                (fixture / 'manifest.json').write_bytes(metadata)
                with patch('historical_migration.MANIFEST_SHA256', hashlib.sha256(metadata).hexdigest()):
                    with self.assertRaises(ValueError): verify_historical(fixture)

    def test_exact_validated_inventory_is_materialized(self):
        with frozen_tree() as root:
            meta = json.loads((FIXTURE / 'manifest.json').read_text())
            actual = sorted(p.relative_to(root).as_posix() for p in root.rglob('*') if p.is_file())
            self.assertEqual(actual, sorted(row['path'] for row in meta['entries']))
            self.assertEqual(len(actual), 101)

if __name__ == '__main__': unittest.main()
