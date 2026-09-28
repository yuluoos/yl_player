"""Offline CLI contract tests. No network or DRM license requests."""
import datetime
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
DART = shutil.which('dart')


class PrepareTest(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(DART, 'dart must be available on PATH')
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for relative in ['tool/drm_acceptance/prepare.dart',
                         'packages/yl_player/example/integration_test/support/drm_acceptance_case.dart']:
            target = self.root / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(REPO / relative, target)
        self.private = self.root / '.drm-acceptance-private'
        self.private.mkdir()
        self.inventory = self.private / 'inventory.json'
        self.output = self.private / 'run.json'
        self.row = json.loads((REPO / 'tool/drm_acceptance/inventory.example.json').read_text())['cases'][0]
        self.row.update(mediaUrl='https://media.test/SECRET_MEDIA',
                        licenseUrl='https://license.test/SECRET_LICENSE',
                        licenseCredentials={'Authorization': 'Bearer SECRET_TOKEN'},
                        mediaSha256='a' * 64,
                        authorizationScope='drm-playback-testing',
                        authorizationExpiresAt=(datetime.datetime.now(datetime.timezone.utc)
                            + datetime.timedelta(days=1)).strftime('%Y-%m-%dT%H:%M:%SZ'),
                        deviceId='SECRET_DEVICE', deviceModel='private model', osVersion='private OS',
                        physicalDevice=True)

    def run_cli(self, *args):
        self.inventory.write_text(json.dumps({'schemaVersion': 1, 'cases': [self.row]}))
        result = subprocess.run([DART, str(self.root / 'tool/drm_acceptance/prepare.dart'),
                                 str(self.inventory), *map(str, args)],
                                capture_output=True, text=True, timeout=30)
        for secret in ['SECRET_MEDIA', 'SECRET_LICENSE', 'SECRET_TOKEN', 'SECRET_DEVICE', str(self.inventory)]:
            self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertEqual(result.stderr, '')
        return result, json.loads(result.stdout)

    def test_ready_is_not_playback_evidence(self):
        result, report = self.run_cli()
        self.assertEqual(result.returncode, 0)
        self.assertEqual(report['networkRequests'], 0)
        self.assertEqual(report['cases'][0]['verification'], 'not_run')
        self.assertFalse(report['cases'][0]['mediaHashVerified'])
        self.assertFalse(self.output.exists())

    def test_missing_blocks_generation(self):
        self.row['licenseUrl'] = ''
        result, report = self.run_cli('android-widevine', self.output)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report['cases'][0]['verification'], 'external_missing')
        self.assertIn('licenseUrl', report['cases'][0]['missing'])
        self.assertFalse(self.output.exists())

    def test_private_exclusive_output(self):
        result, _ = self.run_cli('android-widevine', self.output)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(stat.S_IMODE(self.private.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        original = self.output.read_bytes()
        self.assertEqual(json.loads(json.loads(original)['YL_DRM_CASE']), self.row)
        result, report = self.run_cli('android-widevine', self.output)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report['code'], 'drm.acceptance_config_invalid')
        self.assertEqual(self.output.read_bytes(), original)

    def test_outside_private_root_rejected(self):
        outside = self.root / 'public.json'
        result, _ = self.run_cli('android-widevine', outside)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(outside.exists())

    def test_output_symlink_preserves_target(self):
        target = self.root / 'untouched'
        target.write_text('original')
        self.output.symlink_to(target)
        result, _ = self.run_cli('android-widevine', self.output)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(target.read_text(), 'original')

    def test_private_root_symlink_rejected(self):
        self.inventory.unlink(missing_ok=True)
        self.private.rmdir()
        target = self.root / 'other'
        target.mkdir()
        self.private.symlink_to(target, target_is_directory=True)
        result, _ = self.run_cli('android-widevine', self.output)
        self.assertEqual(result.returncode, 2)
        self.assertFalse(self.output.exists())

    def test_invalid_metadata_is_redacted(self):
        self.row['caseId'] = 'SECRET_TOKEN'
        result, report = self.run_cli()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(report['code'], 'drm.acceptance_config_invalid')


if __name__ == '__main__':
    unittest.main()
