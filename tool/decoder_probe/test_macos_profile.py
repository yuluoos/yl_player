"""Synthetic receipt tests. No profiles from these fixtures are deployed."""
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from macos_profile import digest, issue, LIMIT_NAMES


class MacOSProfileTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.app = self.root / 'example.app'
        contents = self.app / 'Contents'
        contents.mkdir(parents=True)
        payload = {'Contents/Info.plist': plistlib.dumps({'CFBundleIdentifier': 'dev.ylplayer.ylPlayerExample'}),
                   'swift-image': b'swift', 'codec-image': b'codec', 'fixture': b'fixture'}
        for name, data in payload.items():
            (self.app / name).write_bytes(data)
        files = {name: digest(data) for name, data in payload.items()}
        self.protocol = self.root / 'protocol.json'
        ceilings = dict(zip(LIMIT_NAMES, (65536, 8, 4096, 1000000, 1000000)))
        video = dict(codec=12, profile=0, bitDepth=8, chroma=420, width=320, height=180,
                     fpsNumerator=24, fpsDenominator=1, threads=2, outputPixelFormat=875704438)
        self.protocol.write_text(json.dumps(dict(independentProcesses=2, minimumPlaybackSeconds=1200,
            requiredDroppedFrames=0, expectedVideoPackets=28800, trialCeilings=ceilings, cpuWindowNs=1000000000,
            fixturePath='fixture', fixtureSha256=files['fixture'], videoConfiguration=video)))
        peaks = dict.fromkeys(LIMIT_NAMES, 1)
        for pid, mode in enumerate(('baseline', 'verification'), 1):
            folder = self.root / mode
            folder.mkdir()
            plan = dict(product=files, protocolSha256=digest(self.protocol.read_bytes()))
            if mode == 'baseline':
                (folder/'limits.json').write_text(json.dumps(dict(ceilings, maxFrames=2, windowNs=1000000000)))
            else:
                plan['limitsSha256'] = digest((self.root/'baseline/limits.json').read_bytes())
            (folder/'plan.json').write_text(json.dumps(plan))
            (folder/'receipt.json').write_text(json.dumps(dict(passed=True, exit=0, pid=pid, peaks=peaks)))
            images = f"{files['swift-image']}:{files['codec-image']}"
            raw = [f"QUAL_ID M1-test OS {images} {str(mode == 'verification').lower()}"]
            for index in range(601):
                us = index * 2000000
                raw.append(f'QUAL_SAMPLE lease-{pid} {us * 1000} 1 1 1 1 1')
                state = dict(position=us, us=us, status='completed' if index == 600 else 'playing', decoder='software', drops=0)
                raw.append('QUAL_DART '+json.dumps(state))
                raw.append('QUAL_SYSTEM '+json.dumps(dict(status='observed', droppedFrames=0, corruptedFrames=0,
                                                          totalFrames=index*48)))
            raw.extend(('QUAL_DECODED 28800', 'QUAL_FINISH 0'))
            (folder/'raw.log').write_text('\n'.join(raw)+'\n')

    def profile(self):
        return issue(self.app, self.root/'baseline', self.root/'verification', self.protocol)

    @patch('macos_profile.subprocess.run')
    def test_binds_frozen_limits_and_both_images(self, signature):
        signature.return_value.returncode = 0
        profile = self.profile()
        self.assertEqual(profile['key']['decoderBuild'], digest(b'swift')+':'+digest(b'codec'))
        self.assertEqual(profile['limits']['maxFrames'], 2)
        (self.app/'swift-image').write_bytes(b'relinked')
        with self.assertRaisesRegex(ValueError, 'frozen example'):
            self.profile()

    def test_raw_failure_cannot_be_hidden_by_cached_success(self):
        path = self.root/'verification/raw.log'
        with path.open('a') as raw:
            raw.write('QUAL_ERROR resource.exhausted\n')
        with self.assertRaisesRegex(ValueError, 'resource|playback'):
            self.profile()

    def test_changed_resource_ceiling_cannot_be_issued(self):
        path = self.root/'baseline/limits.json'
        caps = json.loads(path.read_text())
        caps['maxDecodeWallNs'] += 1000000
        path.write_text(json.dumps(caps))
        with self.assertRaisesRegex(ValueError, 'frozen limits'):
            self.profile()


if __name__ == '__main__':
    unittest.main()
