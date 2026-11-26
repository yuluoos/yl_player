import json
from pathlib import Path
import re
import tempfile
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ci_playback_shards as shards


class PlaybackShardTest(unittest.TestCase):
    def test_canonical_native_partition_includes_the_conditional_hardware_skip(self):
        sys.path.insert(0, str(shards.ROOT / 'tool/consumer_fixtures/apple_flutter'))
        from main_example_tests import R19_CASE, expected_identities
        canonical = expected_identities(shards.ROOT / 'tool/consumer_fixtures/apple_flutter', 'ios')
        physical = json.loads(shards.MANIFEST.read_text())['iosNativePhysical']
        self.assertIn(R19_CASE, physical)
        self.assertEqual(len(set(physical)), len(physical))
        self.assertEqual(len(physical), 34)
        self.assertLess(set(physical), canonical)

    def test_flutter_partitions_cover_current_suites_and_share_only_dual_contract(self):
        manifest = json.loads(shards.MANIFEST.read_text())
        for platform, expected in [('android24', (2, 9, 0)), ('ios', (11, 23, 1))]:
            sim, physical = set(), set()
            for suite in manifest[platform]:
                sim.update((suite, n) for n in shards.flutter_cases(platform, suite, 'simulator'))
                physical.update((suite, n) for n in shards.flutter_cases(platform, suite, 'physical'))
            self.assertEqual((len(sim), len(physical), len(sim & physical)), expected)

    def test_receipt_cannot_substitute_missing_skipped_extra_or_repeated_tests(self):
        name = 'video [AVC] (file)'
        self.assertIsNotNone(re.fullmatch(shards.name_filter([name]), name))
        self.assertIsNone(re.fullmatch(shards.name_filter([name], exclude=True), name))
        self.assertIsNotNone(re.fullmatch(shards.name_filter([name], exclude=True), 'new video case'))
        with tempfile.TemporaryDirectory() as tmp:
            report = Path(tmp) / 'tests.jsonl'
            start = dict(type='testStart', test=dict(id=1, name=name))
            passed = dict(type='testDone', testID=1, hidden=False, skipped=False, result='success')
            end = dict(type='done', success=True)
            def write(events):
                report.write_text(''.join(json.dumps(e)+'\n' for e in events))
            write([start, passed, end])
            shards.verify_flutter_report(report, [name])
            for events in ([start, end], [start, dict(passed, skipped=True), end],
                           [start, passed, passed, end], [start, passed]):
                write(events)
                with self.assertRaises(ValueError):
                    shards.verify_flutter_report(report, [name])

    def test_real_device_gate_rejects_emulator_wrong_platform_and_wrong_sdk(self):
        def devices(platform, emulator):
            return json.dumps([dict(id='chosen', targetPlatform=platform, emulator=emulator)])
        for record in [devices('android-arm64', True), devices('ios', False)]:
            with patch.object(shards.subprocess, 'check_output', return_value=record):
                with self.assertRaises(ValueError):
                    shards.verify_device('android', 'chosen', 'physical')
        with patch.object(shards.subprocess, 'check_output', side_effect=[devices('android-arm64', False), '36']):
            with self.assertRaises(ValueError):
                shards.verify_device('android', 'chosen', 'physical')
