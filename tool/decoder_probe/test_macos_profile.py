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
        ceilings = dict(zip(LIMIT_NAMES, (65536, 8, 4096, 1000000, 42000000)))
        video = dict(codec=12, profile=0, bitDepth=8, chroma=420, width=320, height=180,
                     fpsNumerator=24, fpsDenominator=1, threads=1, outputPixelFormat=875704438)
        self.protocol.write_text(json.dumps(dict(independentProcesses=2, minimumPlaybackSeconds=1200,
            requiredDroppedFrames=0, expectedVideoPackets=28800, fixedDecodeWallNs=42000000, controlPrelude="public-file-http-paused-readback-seek-v1", trialCeilings=ceilings, cpuWindowNs=1000000000,
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
            for transport in ['file', 'http']:
                markers = [{'phase': phase, 'marker': marker, 'rgb': rgb} for phase, marker, rgb in [
                    ('play', 0, [255, 0, 0]), ('play', 1, [0, 255, 0]),
                    ('play', 2, [0, 0, 255]), ('play', 3, [255, 255, 255]),
                    ('seek-2000', 2, [0, 0, 255]), ('seek-1250', 1, [0, 255, 0]),
                    ('seek-0', 0, [255, 0, 0])]]
                raw.append('PUBLIC_PLAYBACK '+json.dumps(dict(transport=transport, decoder='software',
                    completed=True, markers=markers, requests=[dict(status=206)] if transport=='http' else [],
                    systemSamples=[dict(phase=phase, status='observed', totalFrames=1,
                        droppedFrames=0, corruptedFrames=0, windowOcclusionVisible=True)
                        for phase in ['play-0', 'play-1', 'play-2', 'play-3',
                            'before-seek-2000', 'seek-2000', 'before-seek-1250', 'seek-1250',
                            'before-seek-0', 'seek-0', 'completed']],
                    pixelVerificationMethod='native-renderer-displayed-buffer', readbackWhilePaused=True, acousticOutputVerified=False)))
                raw.append('PUBLIC_DISPOSE '+json.dumps(dict(transport=transport, elapsedUs=1000)))
            raw.append('QUAL_CONTINUOUS_START 480')
            for index in range(601):
                us = index * 2000000
                raw.append(f'QUAL_SAMPLE lease-{pid} {us * 1000} 1 1 1 1 1')
                state = dict(position=us, us=us, status='completed' if index == 600 else 'playing', decoder='software', drops=0)
                raw.append('QUAL_DART '+json.dumps(state))
                raw.append('QUAL_CLOCK '+json.dumps(dict(hostNs=us*1000, samples=index+1,
                    staleEvents=0, maximumReadSeconds=0.001, maximumAgeSeconds=0.02,
                    maximumWorkerGapSeconds=0.01)))
                raw.append('QUAL_SYSTEM '+json.dumps(dict(status='observed', droppedFrames=0, corruptedFrames=0,
                                                          totalFrames=index*48)))
            raw.extend(('QUAL_TOTAL_DECODED 29280', 'QUAL_DECODED 28800', 'QUAL_FINISH 0'))
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

    @patch('macos_profile.subprocess.run')
    def test_counts_first_frame_only_from_distinct_observed_preplay_layer(self, signature):
        signature.return_value.returncode = 0
        path = self.root/'baseline/raw.log'
        rows = path.read_text().splitlines()
        for index, line in enumerate(rows):
            if line.startswith('QUAL_SYSTEM '):
                row = json.loads(line.split(' ', 1)[1])
                row['layerIdentity'] = 'timed'
                row['totalFrames'] = max(0, row['totalFrames'] - 1)
                rows[index] = 'QUAL_SYSTEM '+json.dumps(row)
        preflight = dict(positionUs=0, decoder='software', firstFrameCompleted=True,
            layer=dict(status='observed', layerIdentity='preview', totalFrames=1,
                droppedFrames=0, corruptedFrames=0, surfaceHasBounds=True, windowOcclusionVisible=True))
        rows.append('QUAL_PREFLIGHT '+json.dumps(preflight))
        path.write_text('\n'.join(rows)+'\n')
        self.assertEqual(self.profile()['key']['threads'], 1)
        for change in ({'layerIdentity': 'timed'}, {'droppedFrames': 1}, {'totalFrames': 2}):
            bad = dict(preflight, layer=dict(preflight['layer'], **change))
            path.write_text('\n'.join(rows[:-1]+['QUAL_PREFLIGHT '+json.dumps(bad)])+'\n')
            with self.assertRaisesRegex(ValueError, 'unaccounted displayed frames'):
                self.profile()

    @patch('macos_profile.subprocess.run')
    def test_uses_predeclared_wall_deadline_and_rejects_exceeding_it(self, signature):
        signature.return_value.returncode = 0
        for phase, wall in [('baseline', 17279791), ('verification', 22400125)]:
            folder = self.root/phase
            rows = (folder/'raw.log').read_text().splitlines()
            rows = [' '.join(line.split()[:-1]+[str(wall)]) if line.startswith('QUAL_SAMPLE ') else line for line in rows]
            (folder/'raw.log').write_text('\n'.join(rows)+'\n')
            receipt = json.loads((folder/'receipt.json').read_text())
            receipt['peaks']['maxDecodeWallNs'] = wall
            (folder/'receipt.json').write_text(json.dumps(receipt))
        self.assertEqual(self.profile()['limits']['maxDecodeWallNs'], 42000000)
        folder = self.root/'verification'
        (folder/'raw.log').write_text((folder/'raw.log').read_text().replace('22400125', '42000001'))
        receipt = json.loads((folder/'receipt.json').read_text())
        receipt['peaks']['maxDecodeWallNs'] = 42000001
        (folder/'receipt.json').write_text(json.dumps(receipt))
        with self.assertRaisesRegex(ValueError, 'unqualified limits'):
            self.profile()

    @patch('macos_profile.subprocess.run')
    def test_requires_complete_control_prelude_and_exact_continuous_frame_offset(self, signature):
        signature.return_value.returncode = 0
        path = self.root/'baseline/raw.log'
        original = path.read_text()
        mutations = [
            '\n'.join(line for line in original.splitlines() if not line.startswith('PUBLIC_PLAYBACK '))+'\n',
            original.replace('QUAL_TOTAL_DECODED 29280', 'QUAL_TOTAL_DECODED 29281'),
            original.replace('"elapsedUs": 1000', '"elapsedUs": 3000001'),
            original.replace('"readbackWhilePaused": true', '"readbackWhilePaused": false'),
            original.replace('"droppedFrames": 0', '"droppedFrames": 1', 1),
            original.replace('"phase": "before-seek-2000"', '"phase": "missing-epoch"', 1),
        ]
        for changed in mutations:
            path.write_text(changed)
            with self.subTest(), self.assertRaisesRegex(ValueError, 'prelude|decoded'):
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

    @patch('macos_profile.subprocess.run')
    def test_stale_or_missing_clock_cannot_qualify_zero_drop_playback(self, signature):
        signature.return_value.returncode = 0
        path = self.root/'verification/raw.log'
        original = path.read_text().splitlines()
        for change in ({'staleEvents': 1}, {'maximumWorkerGapSeconds': 0.101}, None):
            rows = []
            for line in original:
                if line.startswith('QUAL_CLOCK '):
                    if change is None:
                        continue
                    value = json.loads(line.split(' ', 1)[1])
                    value.update(change)
                    line = 'QUAL_CLOCK '+json.dumps(value)
                rows.append(line)
            path.write_text('\n'.join(rows)+'\n')
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, 'clock|worker'):
                self.profile()


if __name__ == '__main__':
    unittest.main()
