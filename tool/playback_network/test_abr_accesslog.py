import copy
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
import abr_accesslog
from abr_accesslog import cleanup_owned, observe_owned
from abr_accesslog import summarize

class AccessLogTests(unittest.TestCase):
    def test_candidate_preparation_is_explicit_and_limited_to_owned_auto_probe(self):
        def args(**kwargs):
            values = dict(recovery_action='auto-reload', duration_seconds=120, direct_hls_control=False)
            values.update(kwargs)
            return SimpleNamespace(**values)
        self.assertEqual(abr_accesslog.candidate_preparation(args()), 'manifest-only')
        self.assertEqual(abr_accesslog.candidate_preparation(args(candidate_preparation='asset-metadata')), 'asset-metadata')
        for changes in [dict(candidate_preparation='unknown'),
                        dict(candidate_preparation='asset-metadata', recovery_action='none'),
                        dict(candidate_preparation='asset-metadata', duration_seconds=40),
                        dict(candidate_preparation='asset-metadata', direct_hls_control=True)]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                abr_accesslog.candidate_preparation(args(**changes))

    def test_candidate_preparation_requires_native_echo_and_rejects_mixed_modes(self):
        validate = abr_accesslog.validate_candidate_preparation
        validate([{}, {}], 'manifest-only') # Historical captures predate this diagnostic.
        validate([dict(candidatePreparation='asset-metadata')] * 2, 'asset-metadata')
        for rows in [[], [{}, {}], [dict(candidatePreparation='manifest-only')],
                     [dict(candidatePreparation='asset-metadata'), {}],
                     [dict(candidatePreparation='asset-metadata'), dict(candidatePreparation='manifest-only')],
                     [None]]:
            with self.subTest(rows=rows), self.assertRaises(ValueError):
                validate(rows, 'asset-metadata')
        with self.assertRaises(ValueError):
            validate([dict(candidatePreparation='asset-metadata')], 'manifest-only')

    def test_preparation_window_cannot_be_attributed_to_installed_recovery(self):
        rows = self.rows()
        for row in rows: row.update(recoveryAction='auto-reload', automaticAttempts=0, automaticEvents=[])
        rows[2]['width'] = 640
        rows[-1].update(automaticAttempts=1, automaticEvents=[dict(attempt=1,
            elapsed=1.5, elapsedAfter=2.5, due=1.5, generation=0, positionBefore=1,
            outcome='installed', itemChanged=True)])
        self.assertFalse(summarize(rows, expected_recovery_action='auto-reload')['highOutputAfterInterventionObserved'])

    def test_frame_boundary_reports_stall_and_retention_without_counting_held_frame(self):
        rows = [dict(elapsed=0, generation=0, frames=1, width=320, position=1, textureClears=1),
                dict(elapsed=.02, generation=1, frames=0, width=0, position=0, textureClears=1),
                dict(elapsed=.1, generation=1, frames=1, width=640, position=1.01, textureClears=1)]
        result = abr_accesslog.summarize_frames(rows, expected_frames=2)
        boundary = result['replacementBoundaries'][0]
        self.assertAlmostEqual(boundary['publicationGapMs'], 100)
        self.assertAlmostEqual(boundary['positionDeltaMs'], 10)
        self.assertEqual(boundary['textureClears'], 0)
        self.assertEqual(result['publishedFrames'], 2)
        self.assertFalse(result['continuityAccepted'])
        for value in [-1, True, None]:
            bad = copy.deepcopy(rows); bad[-1]['textureClears'] = value
            with self.subTest(value=value), self.assertRaises(ValueError):
                abr_accesslog.summarize_frames(bad, expected_frames=2)
        missing = copy.deepcopy(rows); del missing[1]['textureClears']
        with self.assertRaises(ValueError): abr_accesslog.summarize_frames(missing, expected_frames=2)
        historical = [{key: value for key, value in row.items() if key != 'textureClears'} for row in rows]
        self.assertIsNone(abr_accesslog.summarize_frames(historical, expected_frames=2)
                          ['replacementBoundaries'][0]['textureClears'])
        # A failed intermediate item and a final item with no frame remain visible.
        rows[-1]['generation'] = 2
        rows.append(dict(elapsed=.12, generation=3, frames=0, width=0, position=0, textureClears=2))
        self.assertEqual(abr_accesslog.summarize_frames(rows, expected_frames=2)
                         ['generationsWithoutPublishedFrame'], [1, 3])

    def test_terminal_no_publication_is_not_hidden_by_last_interframe_gap(self):
        rows = [dict(elapsed=0, generation=0, frames=1, width=320, position=1),
                dict(elapsed=.05, generation=0, frames=1, width=320, position=1.05),
                dict(elapsed=30, generation=0, frames=0, width=0, position=1.05)]
        result = abr_accesslog.summarize_frames(rows, expected_frames=2)
        self.assertAlmostEqual(result['maximumPublishedFrameGapMs'], 50)
        self.assertAlmostEqual(result['trailingNoPublicationMs'], 29950)
        self.assertEqual(result['lastPublicationSampleElapsed'], .05)
        self.assertEqual(result['observationEndElapsed'], 30)
        self.assertFalse(result['continuityAccepted'])
        # A final publication means no observed trailing interval; it does not
        # prove there was no stall after collection stopped.
        rows[-1].update(frames=1, width=640)
        self.assertEqual(abr_accesslog.summarize_frames(rows, expected_frames=3)
                         ['trailingNoPublicationMs'], 0)

    def test_auto_budget_receipt_does_not_require_or_invent_a_recovery(self):
        rows = self.rows()
        for row in rows: row.update(recoveryAction='auto-reload', automaticAttempts=0, automaticEvents=[])
        result = summarize(rows, expected_recovery_action='auto-reload')
        self.assertFalse(result['recoveryInterventionApplied'])
        event = dict(attempt=1, elapsed=2.1, elapsedAfter=2.2, due=2.0,
                     generation=0, positionBefore=2, outcome='installed', itemChanged=True)
        rows[-1].update(automaticAttempts=1, automaticEvents=[event], width=640)
        self.assertTrue(summarize(rows, expected_recovery_action='auto-reload')['recoveryInterventionApplied'])
        with self.assertRaises(ValueError):
            summarize(rows, expected_recovery_action='auto-reload', expected_auto_scenario='pause-first')
        for key, value in [('automaticAttempts', 3), ('automaticEvents', [dict(event, itemChanged=False)]),
                           ('automaticEvents', [dict(event, outcome='preparing')])]:
            bad = copy.deepcopy(rows); bad[-1][key] = value
            with self.assertRaises(ValueError): summarize(bad, expected_recovery_action='auto-reload')

    def test_independent_frame_samples_measure_publication_not_audio_acceptance(self):
        rows = [dict(elapsed=0, generation=0, frames=1, width=320, position=0),
                dict(elapsed=.02, generation=1, frames=0, width=0, position=0),
                dict(elapsed=.1, generation=1, frames=1, width=640, position=.05)]
        result = abr_accesslog.summarize_frames(rows, expected_frames=2)
        self.assertAlmostEqual(result['maximumPublishedFrameGapMs'], 100)
        self.assertAlmostEqual(result['maximumPumpGapMs'], 80)
        self.assertFalse(result['continuityAccepted'])
        with self.assertRaises(ValueError): abr_accesslog.summarize_frames(rows, expected_frames=3)
    def test_recovery_intervention_is_bound_and_not_natural_adaptation(self):
        rows = self.rows()
        for row in rows:
            row.update(recoveryAction='reload-source', recoveryAttempt=None)
        rows[-1].update(width=640, recoveryAttempt=dict(action='reload-source',
            elapsed=2.5, positionBefore=2.0, itemChanged=True, completed=True))
        result = summarize(rows, expected_recovery_action='reload-source')
        self.assertTrue(result['upshiftAfterDownshiftObserved'])
        self.assertTrue(result['recoveryInterventionApplied'])
        self.assertTrue(result['highOutputAfterInterventionObserved'])
        self.assertFalse(result['capabilityAccepted'])
        with self.assertRaises(ValueError): summarize(rows)
        for change in ('missing-action', 'wrong-action', 'missing-attempt', 'incomplete', 'unchanged-item'):
            bad = copy.deepcopy(rows)
            if change == 'missing-action': bad[0].pop('recoveryAction')
            if change == 'wrong-action': bad[-1]['recoveryAction'] = 'seek-current'
            if change == 'missing-attempt': bad[-1]['recoveryAttempt'] = None
            if change == 'incomplete': bad[-1]['recoveryAttempt']['completed'] = False
            if change == 'unchanged-item': bad[-1]['recoveryAttempt']['itemChanged'] = False
            with self.subTest(change=change), self.assertRaises(ValueError):
                summarize(bad, expected_recovery_action='reload-source')

    def test_high_before_operation_and_missing_final_attempt_cannot_claim_recovery(self):
        rows = self.rows()
        attempt = dict(action='seek-current', elapsed=2.5, positionBefore=2,
                       itemChanged=False, completed=True)
        for row in rows: row.update(recoveryAction='seek-current', recoveryAttempt=None)
        rows[-1]['recoveryAttempt'] = attempt
        result = summarize(rows, expected_recovery_action='seek-current')
        self.assertFalse(result['highOutputAfterInterventionObserved'])
        rows[2]['recoveryAttempt'] = attempt; rows[-1]['recoveryAttempt'] = None
        with self.assertRaises(ValueError): summarize(rows, expected_recovery_action='seek-current')

    def test_control_receipt_requires_native_transport_duration_and_full_completion(self):
        rows = self.rows()
        for index, row in enumerate(rows):
            row.update(elapsed=index * 40 + 1, position=index * 40,
                       transport='direct-hls-control', programmeDurationSeconds=120, startupDelayMs=0)
        self.assertFalse(summarize(rows, expected_duration_seconds=120,
                                   expected_transport='direct-hls-control')['capabilityAccepted'])
        for key, value in [('transport', 'managed-dash'), ('transport', None),
                           ('programmeDurationSeconds', 40), ('programmeDurationSeconds', 120.0),
                           ('startupDelayMs', 1000), ('startupDelayMs', None), ('position', 40)]:
            bad = copy.deepcopy(rows); bad[-1][key] = value
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                summarize(bad, expected_duration_seconds=120, expected_transport='direct-hls-control')
        with self.assertRaises(ValueError):
            summarize([None, None], expected_duration_seconds=120, expected_transport='direct-hls-control')

    def rows(self):
        return [dict(elapsed=i,position=i,rate=0 if i==3 else 1,status=1,width=w,height=180,
                     peak=0,forwardBuffer=10,completed=i==3,framesPublished=i,frameSamplingVersion=2,autoScenario='normal',
                     logs=[dict(observedBitrate=600000,indicatedBitrate=414000)])
                for i,w in enumerate((320,640,320,320))]

    def test_preserves_downshift_without_claiming_recovery_or_cause(self):
        result=summarize(self.rows())
        self.assertEqual(result['geometryWidths'],[320,640,320])
        self.assertFalse(result['upshiftAfterDownshiftObserved'])
        self.assertEqual(result['lastObservedBitrate'],600000)
        self.assertFalse(result['internalABRDecisionVerified'])

    def test_detects_recovered_output_but_never_admits_capability(self):
        rows=self.rows();rows[-1]['width']=640
        result=summarize(rows)
        self.assertTrue(result['upshiftAfterDownshiftObserved'])
        self.assertFalse(result['capabilityAccepted'])

    def test_missing_completion_frames_invalid_time_and_nonzero_cap_fail(self):
        variants=[[]]
        for key,value in [('completed',False),('framesPublished',0),('elapsed',float('nan')),('peak',1)]:
            rows=self.rows();rows[-1][key]=value;variants.append(rows)
        for rows in variants:
            with self.subTest(rows=rows),self.assertRaises(ValueError):summarize(rows)

class CleanupTests(unittest.TestCase):
    def test_missing_and_changed_identity_never_signals(self):
        for current in ('', 'different executable/start time'):
            with patch('abr_accesslog.process_identity', return_value=current), patch('abr_accesslog.os.kill') as kill:
                self.assertEqual(cleanup_owned((123, 'original')), current == '')
                kill.assert_not_called()

    def test_matching_identity_is_terminated_and_verified(self):
        with patch('abr_accesslog.process_identity', side_effect=['original', '']), patch('abr_accesslog.os.kill') as kill:
            self.assertTrue(cleanup_owned((123, 'original')))
            kill.assert_called_once()


class FailureReceiptTests(unittest.TestCase):
    def _failed_playback_receipt(self, raw_rows):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); products = root / 'products'; app = products / 'Fixture.app'
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Fixture'}))
            (app / 'Fixture').write_bytes(b'unit fixture, never launched')
            (products / 'probe.xctestrun').write_bytes(plistlib.dumps({
                'RunnerTests': {'TestHostPath': '__TESTROOT__/Fixture.app/Fixture'}}))
            args = SimpleNamespace(products=products, directory=root/'out', device=None,
                profiles=Path(__file__).with_name('profiles.json'), profile='down-and-recover-v1')
            def failed_native(*_args):
                # Deliberately incomplete main rows cannot satisfy playback acceptance.
                (args.directory/'rows.jsonl').write_text(raw_rows)
                frames = [dict(elapsed=0, generation=0, frames=1, width=320, position=1),
                          dict(elapsed=.05, generation=0, frames=1, width=320, position=1.05),
                          dict(elapsed=30, generation=0, frames=0, width=0, position=1.05)]
                (args.directory/'frame-samples.jsonl').write_text(''.join(json.dumps(x)+'\n' for x in frames))
                return 65
            process = Mock(); process.poll.return_value = 0
            with patch('abr_accesslog.subprocess.Popen', return_value=process), \
                 patch('abr_accesslog.wait_for_native', side_effect=failed_native), \
                 patch('abr_accesslog.cleanup_owned', return_value=True):
                receipt = abr_accesslog.run(args)
            return receipt

    def test_empty_main_rows_fail_closed_without_escaping(self):
        receipt = self._failed_playback_receipt('')
        self.assertFalse(receipt['passed'])
        self.assertEqual(receipt['exitCode'], 65)
        self.assertIn('ValueError', receipt['errors'])
        self.assertNotIn('continuityObservation', receipt)

    def test_failed_playback_retains_valid_frame_observation_without_passing(self):
        receipt = self._failed_playback_receipt('{"framesPublished": 2}\n{"framesPublished": 2}\n')
        self.assertFalse(receipt['passed'])
        self.assertEqual(receipt['exitCode'], 65)
        self.assertNotIn('observation', receipt)
        self.assertAlmostEqual(receipt['continuityObservation']['trailingNoPublicationMs'], 29950)
        self.assertFalse(receipt['continuityObservation']['continuityAccepted'])

    def test_direct_control_duration_and_identity_survive_failure_before_launch(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); products = root / 'products'
            app = products / 'Fixture.app'; app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'Fixture'}))
            (app / 'Fixture').write_bytes(b'not launched')
            (products / 'probe.xctestrun').write_bytes(plistlib.dumps({
                'RunnerTests': {'TestHostPath': '__TESTROOT__/Fixture.app/Fixture'}}))
            args = SimpleNamespace(products=products, directory=root / 'out', device=None,
                duration_seconds=120, direct_hls_control=True,
                profiles=Path(__file__).with_name('profiles.json'), profile='down-and-recover-v1')
            # Abort at the server boundary, after real preparation; no fake native success.
            with patch('abr_accesslog.make_server', side_effect=ValueError('stop before launch')):
                receipt = abr_accesslog.run(args)
            self.assertEqual(receipt['fixture']['durationSeconds'], 120)
            self.assertEqual(receipt['transport'], 'direct-hls-control')
            self.assertTrue((root / 'out/fixture/direct-master.m3u8').is_file())
            self.assertFalse(receipt['passed'])
            self.assertIsNone(receipt['exitCode'])

    def test_preflight_failures_keep_a_failed_receipt_without_running_a_host(self):
        # Losing failures before launch makes the recorded experiment denominator wrong.
        for kind in ('missing-products', 'missing-manifest', 'invalid-manifest', 'truncated-xml', 'missing-host'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                products, output = root / 'products', root / 'observation'
                if kind != 'missing-products':
                    products.mkdir()
                if kind == 'invalid-manifest':
                    (products / 'probe.xctestrun').write_bytes(b'not a plist')
                elif kind == 'truncated-xml':
                    (products / 'probe.xctestrun').write_bytes(b'<?xml version="1.0"?><plist><dict>')
                elif kind == 'missing-host':
                    (products / 'probe.xctestrun').write_bytes(plistlib.dumps({'RunnerTests': {}}))
                result = subprocess.run([sys.executable, str(Path(__file__).with_name('abr_accesslog.py')),
                    '--products', str(products), '--directory', str(output)],
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.assertTrue((output / 'receipt.json').exists(), 'preflight failure disappeared')
                receipt = json.loads((output / 'receipt.json').read_text())
                self.assertFalse(receipt['passed'])
                self.assertFalse(receipt['capabilityAccepted'])
                self.assertFalse(receipt['binaryIdentityUnchanged'])
                self.assertIsNone(receipt['exitCode'])
                self.assertTrue(receipt['errors'])
                self.assertNotIn(str(root), result.stdout + result.stderr)
                self.assertNotIn('Traceback', result.stderr)


class ProcessProofTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'macOS native host process proof')
    def test_same_executable_through_path_alias_is_owned_but_other_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app = root / 'host.app'
            app.mkdir()
            executable = app / 'owned-sleep'
            shutil.copy('/bin/sleep', executable)
            # Use a real process so ps's actual executable representation is tested.
            child = subprocess.Popen([str(executable), '20'])
            try:
                proof = dict(pid=child.pid, token='owned-token')
                # Keep the same bundle-shaped pathname as the native proof contract.
                nested = root / 'alias.app'
                nested.symlink_to(app, target_is_directory=True)
                proof['executable'] = str(nested / 'owned-sleep')
                (root / 'process.json').write_text(json.dumps(proof))
                observed = observe_owned(root, 'owned-token', 'owned-sleep')
                self.assertIsNotNone(observed)
                self.assertEqual(observed[0], child.pid)
                other = root / 'other.app'
                other.mkdir()
                shutil.copy('/bin/sleep', other / 'owned-sleep')
                proof['executable'] = str(root / 'other.app' / 'owned-sleep')
                (root / 'process.json').write_text(json.dumps(proof))
                with self.assertRaises(ValueError):
                    observe_owned(root, 'owned-token', 'owned-sleep')
            finally:
                child.terminate()
                child.wait(timeout=5)


class NativeDeadlineTests(unittest.TestCase):
    def test_exit_after_final_sleep_cannot_be_accepted_past_deadline(self):
        wait = getattr(abr_accesslog, 'wait_for_native', None)
        self.assertIsNotNone(wait, 'native exit must be checked against the deadline')
        process = Mock()
        process.poll.side_effect = [None, 0]
        with patch('abr_accesslog.time.monotonic', side_effect=[0, 239.9, 240.1]), \
                patch('abr_accesslog.time.sleep'), self.assertRaises(subprocess.TimeoutExpired):
            wait(process, ['owned-native-command'], lambda: None)

    def test_timely_exit_preserves_actual_failure_code(self):
        wait = getattr(abr_accesslog, 'wait_for_native', None)
        self.assertIsNotNone(wait)
        process = Mock()
        process.poll.side_effect = [None, 65]
        with patch('abr_accesslog.time.monotonic', side_effect=[0, 1, 2]), \
                patch('abr_accesslog.time.sleep'):
            self.assertEqual(wait(process, ['owned-native-command'], lambda: None), 65)


if __name__=='__main__':unittest.main()
