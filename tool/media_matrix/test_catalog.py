"""Protect fixture identity, coverage and platform evidence boundaries."""
import copy
import hashlib
import tempfile
from pathlib import Path
import unittest

from catalog import validate_case, validate_coverage


class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'owned.mp4').write_bytes(b'owned fixture')
        self.row = {
            'id': 'mp4-avc-aac', 'file': 'owned.mp4', 'container': 'mp4',
            'sha256': hashlib.sha256(b'owned fixture').hexdigest(),
            'video': {'codec': 'h264', 'bitDepth': 8, 'profile': 'High'},
            'audio': {'codec': 'aac', 'channels': 2},
            'durationSeconds': 4.0, 'integrity': 'valid', 'seekability': 'expected_seekable',
            'source': 'owned-generated', 'supportRequirement': 'required', 'transports': ['file', 'http'],
            'platforms': {p: {'implementation': 'unverified', 'verification': 'not_run'}
                          for p in ['android', 'ios', 'macos']},
        }

    def test_owned_fixture_identity_is_accepted(self):
        validate_case(self.row, self.root)

    def test_required_video_cannot_be_relabelled_diagnostic(self):
        for codec in ['h264', 'hevc', 'vp9', 'av1']:
            self.row['video']['codec'] = codec
            self.row['supportRequirement'] = 'diagnostic'
            with self.assertRaises(ValueError): validate_case(self.row, self.root)

    def test_only_original_mpeg2_probe_is_diagnostic(self):
        self.row.update(id='ps-mpeg2-mp3', container='mpegPs', supportRequirement='diagnostic')
        self.row['video']['codec'] = 'mpeg2video'
        self.row['audio']['codec'] = 'mp3'
        validate_case(self.row, self.root)
        self.row['supportRequirement'] = 'required'
        with self.assertRaises(ValueError): validate_case(self.row, self.root)
        self.row.update(id='unexpected-diagnostic', supportRequirement='diagnostic')
        with self.assertRaises(ValueError): validate_case(self.row, self.root)

    def test_missing_support_requirement_is_rejected(self):
        del self.row['supportRequirement']
        with self.assertRaises(ValueError): validate_case(self.row, self.root)

    def test_changed_media_is_rejected(self):
        (self.root / 'owned.mp4').write_bytes(b'changed')
        with self.assertRaises(ValueError): validate_case(self.row, self.root)

    def test_path_traversal_is_rejected(self):
        self.row['file'] = '../owned.mp4'
        with self.assertRaises(ValueError): validate_case(self.row, self.root)

    def test_missing_platform_is_not_implicitly_supported(self):
        del self.row['platforms']['ios']
        with self.assertRaises(ValueError): validate_case(self.row, self.root)

    def test_runtime_smoke_cannot_promote_full_format_acceptance(self):
        self.row['platforms']['macos']['verification'] = 'passed'
        with self.assertRaises(ValueError): validate_case(self.row, self.root)

    def test_nonfinite_duration_rejected(self):
        self.row['durationSeconds'] = float('nan')
        with self.assertRaises(ValueError): validate_case(self.row, self.root)

    def test_codec_coverage_cannot_be_claimed_from_avc_alone(self):
        with self.assertRaises(ValueError): validate_coverage([self.row])

    def test_duplicate_case_is_rejected(self):
        with self.assertRaises(ValueError): validate_coverage([self.row, copy.deepcopy(self.row)])


if __name__ == '__main__': unittest.main()
