import copy
import unittest
from run_audio_integration_resources import validate_decoded_rows, eligible_decoded_checkpoint


def rows(candidate=True):
    modes = dict(renderedSubmissions=188 if candidate else 0,
                 renderedCallbacks=188 if candidate else 0,
                 playedSubmissions=1 if candidate else 189,
                 playedCallbacks=1 if candidate else 189)
    result = []
    for index, phase in enumerate(('configured', 'completed', 'drained', 'disposed', 'disposedLater')):
        result.append(dict(phase=phase, uptime=1 + index * 3, pid=42, sessionId=1,
            candidate=candidate, submissionAnchor=candidate and index < 3, pending=False, nativePlaying=phase == 'completed',
            engineRunning=phase not in ('disposed', 'disposedLater'),
            completed=0 if phase == 'configured' else 1, firstFrames=0 if phase == 'configured' else 1,
            ownedBytes=0, ledgerBytes=0, failures=[], modes=copy.deepcopy(modes)))
    return result


class DecodedEOFResourcesTests(unittest.TestCase):
    def test_accepts_both_arms_without_claiming_global_bound(self):
        for arm in (False, True):
            self.assertFalse(validate_decoded_rows(rows(arm), arm)['downstreamBoundProven'])

    def test_heap_guard_rejects_live_pending_uncompleted_or_owned(self):
        for change in (dict(nativePlaying=True), dict(pending=True), dict(completed=0), dict(ownedBytes=1)):
            row=rows()[2]; row.update(change)
            self.assertFalse(eligible_decoded_checkpoint(row))
        self.assertFalse(eligible_decoded_checkpoint(rows()[1]))
        self.assertTrue(eligible_decoded_checkpoint(rows()[0]))

    def test_rejects_incomplete_or_changed_identity_and_modes(self):
        changes = [lambda r:r.pop(1), lambda r:r[-1].update(pid=43),
            lambda r:r[-1].update(candidate=False), lambda r:r[1].update(submissionAnchor=False), lambda r:r[2].update(completed=2),
            lambda r:r[1].update(firstFrames=0), lambda r:r[-1].update(ledgerBytes=1),
            lambda r:r[-1].update(engineRunning=True), lambda r:r[2].update(nativePlaying=True),
            lambda r:r[1].update(pending=True), lambda r:r[-1]['failures'].append('error'),
            lambda r:r[1]['modes'].update(playedCallbacks=0),
            lambda r:r[-1]['modes'].update(renderedCallbacks=187),
            lambda r:r[-1].update(uptime=r[-2]['uptime']+1)]
        for change in changes:
            r=rows();change(r)
            with self.subTest(change=change), self.assertRaises(ValueError):validate_decoded_rows(r,True)

    def test_length_matrix_rejects_wrong_fixture_short_play_and_unbounded_recorder(self):
        for update in (dict(fixtureName='other.mkv'), dict(playbackElapsedSeconds=1),
                       dict(retainedDeltaCount=20), dict(retainedOrderCount=100)):
            r=rows()
            for row in r:
                row.update(fixtureName='decoded-30.mkv', playbackElapsedSeconds=30,
                           retainedDeltaCount=0, retainedOrderCount=0, retainedEventCount=8)
            r[1].update(update)
            with self.subTest(update=update), self.assertRaises(ValueError):
                validate_decoded_rows(r, True, expected_seconds=30, expected_fixture='decoded-30.mkv')

    def test_accepts_measured_length_and_bounded_recorder(self):
        r=rows()
        for row in r:
            row.update(fixtureName='decoded-30.mkv', playbackElapsedSeconds=30,
                       retainedDeltaCount=0, retainedOrderCount=0, retainedEventCount=8)
        self.assertEqual(validate_decoded_rows(r, True, expected_seconds=30,
                         expected_fixture='decoded-30.mkv')['playbackElapsedSeconds'],30)
