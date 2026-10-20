import copy
import unittest
try:
    from summarize_live import summarize
except ImportError:
    summarize = None


def evidence():
    result = dict(schemaVersion=2, runId='live-1', sessionId='session-1', protocol='hls',
                  declaredMediaHash='a'*64, profileId='owned-v1', profileHash='b'*64,
                  platform='macos', outcome='completed', stage='stop', cleaned=True,
                  rapidSwitchVerified=True, staleStopVerified=True,
                  sampleCount=7, endToEndLatencyUs=None, evidence='public-state-only',
                  commits=[dict(mode='lowLatency', elapsedUs=250, revision=3,
                                startedUs=200),
                           dict(mode='smoothPlayback', elapsedUs=550, revision=6,
                                startedUs=500)])
    samples = []
    for t, p, stage, mode, status, revision in [
        (0, 0, 'smooth', 'smoothPlayback', 'playing', 1),
        (100, 100, 'smooth', 'smoothPlayback', 'playing', 2),
        (300, 100, 'paused-low', 'lowLatency', 'paused', 3),
        (400, 100, 'low', 'lowLatency', 'playing', 4),
        (500, 200, 'low', 'lowLatency', 'playing', 5),
        (600, 200, 'smooth-again', 'smoothPlayback', 'playing', 6),
        (700, 300, 'smooth-again', 'smoothPlayback', 'playing', 7)]:
        samples.append(dict(runId='live-1', sessionId='session-1', stage=stage, elapsedUs=t,
            positionUs=p, mediaClockUs=p, revision=revision, mode=mode, status=status,
            failed=False, liveOffsetUs=None, managedBufferedUs=None,
            rebufferCount=None, rebufferUs=None, reconnectCount=None,
            endToEndLatencyUs=None))
    receipt = dict(schemaVersion=1, runId='live-1', protocol='hls',
        declaredMediaHash='a'*64, profileId='owned-v1', profileHash='b'*64,
        cleaned=True, activeConnections=0, acceptedConnections=1,
        recordedConnections=1, rejectedConnections=0,
        phaseBoundariesMs=[0, 10, 20], timelineMode='first-client-bytes',
        byteScope='downstream-tcp-including-protocol-headers')
    connections = [dict(schemaVersion=1, runId='live-1', protocol='hls',
        declaredMediaHash='a'*64, profileId='owned-v1', profileHash='b'*64,
        connectionId=1, startMs=0, endMs=30, upstreamBytesWritten=5,
        downstreamBytesWritten=60, phaseBytes=[10, 20, 30], outcome='complete')]
    return result, samples, receipt, connections


def baseline_evidence(mode='smoothPlayback'):
    result, samples, receipt, connections = evidence()
    result.update(scenario='baseline', baselineMode=mode, sampleCount=2, commits=[],
                  rapidSwitchVerified=False, staleStopVerified=False)
    samples = [dict(samples[0], stage='baseline', mode=mode),
               dict(samples[-1], stage='baseline', mode=mode, elapsedUs=36000000)]
    return result, samples, receipt, connections


class LiveSummaryTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(summarize, 'Live capture validation is missing')

    def test_complete_mode_sequence_retains_unknown_metrics_and_declared_hash(self):
        report = summarize(*evidence(), exit_code=0)
        self.assertTrue(report['captureComplete'])
        self.assertEqual(report['modeSwitchLatencyUs'], [50, 50])
        self.assertEqual(report['networkPhaseBytes'], [10, 20, 30])
        self.assertIsNone(report['rebufferCountDelta'])
        self.assertIsNone(report['endToEndLatencyUs'])
        self.assertFalse(report['physicalOutputVerified'])
        self.assertFalse(report['capabilityAccepted'])
        self.assertFalse(report['mediaIdentityVerified'])

    def test_old_session_mixed_profile_missing_rows_and_forged_byte_sum_rejected(self):
        for mutation in ('session', 'profile', 'count', 'bytes', 'nan'):
            r, s, receipt, connections = evidence()
            if mutation == 'session': s[3]['sessionId'] = 'session-2'
            if mutation == 'profile': receipt['profileHash'] = 'c'*64
            if mutation == 'count': r['sampleCount'] += 1
            if mutation == 'bytes': connections[0]['phaseBytes'][0] += 1
            if mutation == 'nan': s[1]['elapsedUs'] = float('nan')
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                summarize(r, s, receipt, connections, exit_code=0)

    def test_missing_progress_wrong_mode_and_pause_violation_fail(self):
        for mutation, expected in [('progress', 'low_clock_not_advancing'),
                                   ('mode', 'low_mode_mismatch'),
                                   ('paused', 'pause_intent_lost'),
                                   ('rapid', 'rapid_switch_unverified')]:
            r, s, receipt, connections = evidence()
            if mutation == 'progress': s[4]['mediaClockUs'] = s[3]['mediaClockUs']
            if mutation == 'mode': s[4]['mode'] = 'smoothPlayback'
            if mutation == 'paused': s[2]['status'] = 'playing'
            if mutation == 'rapid': r['rapidSwitchVerified'] = False
            report = summarize(r, s, receipt, connections, exit_code=0)
            self.assertIn(expected, report['violations'])
            self.assertFalse(report['captureComplete'])

    def test_failure_timeout_nonzero_exit_cleanup_and_uncovered_phase_stay_visible(self):
        for outcome in ('failed', 'timeout'):
            r, s, receipt, connections = evidence(); r['outcome'] = outcome
            self.assertFalse(summarize(r, s, receipt, connections, exit_code=0)['captureComplete'])
        self.assertFalse(summarize(*evidence(), exit_code=1)['captureComplete'])
        r, s, receipt, connections = evidence(); receipt['cleaned'] = False
        self.assertFalse(summarize(r, s, receipt, connections, exit_code=0)['captureComplete'])
        r, s, receipt, connections = evidence(); connections[0]['phaseBytes'] = [0, 0, 60]
        self.assertEqual(summarize(r, s, receipt, connections, exit_code=0)['networkPhasesObserved'], [2])

    def test_partial_buffer_telemetry_is_not_a_comparable_maximum(self):
        r, s, receipt, connections = evidence()
        s[0]['managedBufferedUs'] = 0
        report = summarize(r, s, receipt, connections, exit_code=0)
        self.assertIsNone(report['maximumManagedBufferedUs'])
        for sample in s: sample['managedBufferedUs'] = 12
        self.assertEqual(summarize(r, s, receipt, connections, exit_code=0)['maximumManagedBufferedUs'], 12)

    def test_each_mode_baseline_covers_full_observation_window(self):
        for mode in ('smoothPlayback', 'lowLatency'):
            r, s, receipt, connections = baseline_evidence(mode)
            report = summarize(r, s, receipt, connections, exit_code=0)
            self.assertTrue(report['captureComplete'])
            s[-1]['elapsedUs'] = 1000
            report = summarize(r, s, receipt, connections, exit_code=0)
            self.assertIn('baseline_window_incomplete', report['violations'])
            s[-1]['elapsedUs'] = 36000000
            s[-1]['mode'] = 'lowLatency' if mode == 'smoothPlayback' else 'smoothPlayback'
            self.assertIn('baseline_mode_mismatch', summarize(r, s, receipt, connections, exit_code=0)['violations'])

    def test_failure_before_create_preserves_empty_capture(self):
        r, s, receipt, connections = evidence()
        r.update(outcome='timeout', stage='create', sampleCount=0, sessionId=None,
                 cleaned=False, commits=[], rapidSwitchVerified=False, staleStopVerified=False)
        report = summarize(r, [], receipt, connections, exit_code=1)
        self.assertFalse(report['captureComplete'])
        self.assertEqual(report['outcome'], 'timeout')

if __name__ == '__main__':
    unittest.main()
