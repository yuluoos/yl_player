"""Offline regressions use owned synthetic scripts, never the private archive."""
import base64
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import generate_controlled_integration as generator

REAL_PACKAGE = generator.PACKAGE


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.package = self.root / 'package'
        self.package.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.package)], check=True)
        (self.package / '.gitignore').write_text('/example/integration_test/generated/\n')
        self.contract = self.package / 'test/support/controlled_contract.dart'
        self.contract.parent.mkdir(parents=True)
        self.archive = self.root / 'private'
        self.archive.mkdir(mode=0o700)
        self.target = self.package / 'example/integration_test/generated/controlled_runtime_test.dart'
        self.payloads = {}
        entries = []
        for n in range(1, 10):
            key = f'JS-{n:02}'
            raw = f'// private synthetic marker {n}\r\nfunction main() {{}}\n'.encode()
            self.payloads[key] = raw
            p = self.archive / f'{n}.js'
            p.write_bytes(raw)
            p.chmod(0o600)
            entries.append(f"  '{key}': ('{n}.js', 'id=owned', '{hashlib.sha256(raw).hexdigest()}',),")
        self.contract.write_text('const frozenScripts = <String, (String, String, String)>{\n' + '\n'.join(entries) + '\n};\n')
        for name, value in [('PACKAGE', self.package), ('TARGET', self.target)]:
            mock = patch.object(generator, name, value)
            mock.start()
            self.addCleanup(mock.stop)

    def invoke(self, *args):
        out, err = io.StringIO(), io.StringIO()
        with patch('sys.argv', ['generator', *map(str, args)]), redirect_stdout(out), redirect_stderr(err):
            try:
                result = generator.main()
                code = result or 0
            except SystemExit as e:
                code = e.code if isinstance(e.code, int) else 1
                if not isinstance(e.code, int):
                    err.write(str(e.code))
        self.assertNotIn('private synthetic marker', out.getvalue() + err.getvalue())
        return code, out.getvalue(), err.getvalue()

    def audit(self):
        code, out, err = self.invoke('--archive', self.archive, '--verify-only')
        return code, json.loads(out), err

    def test_verify_only_reports_all_original_hashes_without_writing(self):
        code, report, err = self.audit()
        self.assertEqual(code, 0, err)
        self.assertEqual(report['status'], 'verified')
        self.assertEqual(len(report['scripts']), 9)
        self.assertFalse(report['executed'])
        for row, (key, raw) in zip(report['scripts'], self.payloads.items()):
            self.assertEqual(row['id'], key)
            self.assertEqual(row['bytes'], len(raw))
            self.assertEqual(row['sha256'], hashlib.sha256(raw).hexdigest())
            self.assertEqual(row['status'], 'verified')
        self.assertFalse(self.target.parent.exists())

    def test_audit_keeps_missing_and_changed_rows_in_denominator(self):
        (self.archive / '1.js').unlink()
        (self.archive / '2.js').write_bytes(b'changed')
        code, report, _ = self.audit()
        self.assertEqual(code, 1)
        self.assertEqual(report['status'], 'failed')
        self.assertEqual(len(report['scripts']), 9)
        self.assertEqual([r['status'] for r in report['scripts'][:2]], ['missing', 'digest_mismatch'])
        self.assertEqual(sum(r['status'] == 'verified' for r in report['scripts']), 7)

    def test_generation_preserves_exact_bytes_and_private_permissions(self):
        code, _, err = self.invoke('--archive', self.archive)
        self.assertEqual(code, 0, err)
        source = self.target.read_text()
        for raw in self.payloads.values():
            self.assertIn(base64.b64encode(raw).decode(), source)
        self.assertEqual(stat.S_IMODE(self.target.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.target.parent.stat().st_mode), 0o700)
        self.assertIn('runtime.registerRuntimeContracts();', source)
        self.assertIn('handoff.registerControlledMediaHandoffs(sources);', source)

    def test_failure_does_not_replace_existing_entry(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b'previous fixture')
        (self.archive / '9.js').write_bytes(b'changed')
        self.assertEqual(self.invoke('--archive', self.archive)[0], 1)
        self.assertEqual(self.target.read_bytes(), b'previous fixture')

    def test_refuses_input_symlink(self):
        p = self.archive / '1.js'
        p.rename(self.root / 'original')
        p.symlink_to(self.root / 'original')
        code, report, _ = self.audit()
        self.assertEqual(code, 1)
        self.assertEqual(report['scripts'][0]['status'], 'not_regular')

    def test_refuses_public_archive_and_file_permissions(self):
        for target in [self.archive, self.archive / '1.js']:
            with self.subTest(target=target.name):
                before = stat.S_IMODE(target.stat().st_mode)
                target.chmod(0o755 if target.is_dir() else 0o644)
                try:
                    code, report, _ = self.audit()
                    self.assertEqual(code, 1)
                    self.assertEqual(report['status'], 'failed')
                finally:
                    target.chmod(before)

    def test_refuses_oversized_script_without_reading_all_of_it(self):
        (self.archive / '1.js').write_bytes(b'x' * (512 * 1024 + 1))
        code, report, _ = self.audit()
        self.assertEqual(code, 1)
        self.assertEqual(report['scripts'][0]['status'], 'too_large')

    def test_refuses_fifo_without_blocking(self):
        p = self.archive / '1.js'
        p.unlink()
        os.mkfifo(p, mode=0o600)
        code, report, _ = self.audit()
        self.assertEqual(code, 1)
        self.assertEqual(report['scripts'][0]['status'], 'not_regular')

    def test_invalid_utf8_has_safe_diagnostic(self):
        raw = b'\xffprivate synthetic marker'
        old = hashlib.sha256(self.payloads['JS-01']).hexdigest()
        self.contract.write_text(self.contract.read_text().replace(old, hashlib.sha256(raw).hexdigest()))
        (self.archive / '1.js').write_bytes(raw)
        code, report, _ = self.audit()
        self.assertEqual(code, 1)
        self.assertEqual(report['scripts'][0]['status'], 'invalid_utf8')

    def test_rejects_invalid_manifest_ids_and_paths(self):
        original = self.contract.read_text()
        for before, after in [("'JS-09'", "'JS-01'"), ("'9.js'", "'../9.js'"), ("'9.js'", "'1.js'")]:
            with self.subTest(after=after):
                self.contract.write_text(original.replace(before, after))
                self.assertEqual(self.invoke('--archive', self.archive)[0], 1)
                self.assertFalse(self.target.exists())

    def test_output_symlink_does_not_overwrite_other_file(self):
        self.target.parent.mkdir(parents=True)
        victim = self.root / 'victim'
        victim.write_bytes(b'keep')
        self.target.symlink_to(victim)
        self.assertEqual(self.invoke('--archive', self.archive)[0], 1)
        self.assertEqual(victim.read_bytes(), b'keep')

    def test_linked_output_directory_refused_for_generation_and_removal(self):
        self.target.parent.parent.mkdir(parents=True)
        outside = self.root / 'outside'
        outside.mkdir()
        self.target.parent.symlink_to(outside, target_is_directory=True)
        victim = outside / self.target.name
        victim.write_bytes(b'keep')
        for args in [('--archive', self.archive), ('--remove',)]:
            with self.subTest(args=args):
                self.assertEqual(self.invoke(*args)[0], 1)
                self.assertEqual(victim.read_bytes(), b'keep')

    def test_refuses_unignored_and_tracked_output(self):
        (self.package / '.gitignore').write_text('')
        self.assertEqual(self.invoke('--archive', self.archive)[0], 1)
        self.assertFalse(self.target.exists())
        self.target.parent.mkdir(parents=True)
        self.target.write_text('tracked')
        subprocess.run(['git', '-C', str(self.package), 'add', '.'], check=True)
        (self.package / '.gitignore').write_text('/example/integration_test/generated/\n')
        self.assertEqual(self.invoke('--archive', self.archive)[0], 1)
        self.assertEqual(self.target.read_text(), 'tracked')

    def test_remove_is_idempotent_and_does_not_touch_archive(self):
        self.assertEqual(self.invoke('--archive', self.archive)[0], 0)
        for _ in range(2):
            self.assertEqual(self.invoke('--remove')[0], 0)
        self.assertFalse(self.target.exists())
        self.assertEqual((self.archive / '1.js').read_bytes(), self.payloads['JS-01'])

    def test_replace_failure_preserves_previous_entry_and_cleans_temporary(self):
        self.target.parent.mkdir(parents=True)
        self.target.write_bytes(b'previous fixture')
        with patch.object(generator.os, 'replace', side_effect=OSError('private synthetic marker')):
            self.assertEqual(self.invoke('--archive', self.archive)[0], 1)
        self.assertEqual(self.target.read_bytes(), b'previous fixture')
        self.assertEqual(list(self.target.parent.iterdir()), [self.target])

    def test_missing_or_linked_archive_reports_nine_unavailable_rows(self):
        for path in [self.root / 'missing', self.root / 'linked']:
            if path.name == 'linked':
                path.symlink_to(self.archive, target_is_directory=True)
            with self.subTest(kind=path.name):
                code, out, _ = self.invoke('--archive', path, '--verify-only')
                report = json.loads(out)
                self.assertEqual(code, 1)
                self.assertEqual(report['archiveStatus'], 'unavailable')
                self.assertEqual([r['status'] for r in report['scripts']], ['archive_unavailable'] * 9)


class FrozenManifestTests(unittest.TestCase):
    def test_shared_contract_still_matches_historical_frozen_ledger(self):
        entries, _ = generator.manifest()
        ledger = (REAL_PACKAGE.parents[1] / 'docs/superpowers/specs/2026-09-20-playback-expansion-intake.md').read_text()
        rows = re.findall(r'\| (JS-\d+) \| ([\w.-]+) \| \d+ \| (\d+) \| `([a-f0-9]{64})` \|', ledger)
        self.assertEqual(len(rows), 9)
        self.assertEqual(entries, [(key, filename, digest) for key, filename, _, digest in rows])


if __name__ == '__main__':
    unittest.main()
