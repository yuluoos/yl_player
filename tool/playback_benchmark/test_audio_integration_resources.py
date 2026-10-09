import copy
from pathlib import Path
import subprocess
import tempfile
import unittest
from run_audio_integration_resources import capture_heap, validate_rows

TABLE = 'Process: yl_player_example [42]\nAll zones: 1 nodes (64 bytes)\n COUNT BYTES AVG CLASS_NAME TYPE BINARY\n 1 64 64.0 ExampleClass  Swift  Example\n'


def rows():
    common = dict(pid=42, generation=1, candidate=True, captureAfterDrain=True,
                  marker=dict(frames=0, errors=0, interiorZeroFrames=0), failures=[],
                  ledgerBytes=0, ownedBytes=0, ledgerPeak=196608,
                  modes=dict(renderedSubmissions=1999, renderedCallbacks=1999,
                             playedSubmissions=1, playedCallbacks=1))
    result=[]
    for phase, uptime in [('configured',1),('playing',23),('drained',46),('disposed',47),('disposedLater',49)]:
        row=copy.deepcopy(common);row.update(phase=phase,uptime=uptime,nativePlaying=phase=='playing',pending=phase=='playing')
        row['marker']['frames']=1024000 if phase=='playing' else (2048000 if phase in ('drained','disposed','disposedLater') else 0)
        result.append(row)
    return result


class AudioIntegrationResourceTests(unittest.TestCase):
    def capture(self, text=TABLE, code=0, error=None):
        def run(command, **kwargs):
            self.assertEqual(command, ['/usr/bin/heap','--noContent','42'])
            self.assertEqual(kwargs['timeout'],8)
            kwargs['stdout'].write(text)
            if error: raise error
            return subprocess.CompletedProcess(command,code)
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'heap.txt';result=capture_heap(42,path,run=run)
            self.assertEqual(path.read_text(),text)
            return result

    def test_accepts_owned_pid_table(self):
        self.assertTrue(self.capture()['valid'])

    def test_rejects_empty_truncated_and_wrong_pid_even_exit_zero(self):
        for text in ['', 'Process: yl_player_example [42]\n', TABLE.replace('[42]','[43]')]:
            with self.subTest(text=text):self.assertFalse(self.capture(text)['valid'])

    def test_timeout_preserves_partial_output_and_is_not_success(self):
        result=self.capture('partial',error=subprocess.TimeoutExpired(['heap'],8))
        self.assertFalse(result['valid']);self.assertIn('TimeoutExpired',result['error'])
        self.assertIsNone(result['exitCode'])

    def test_rejects_partial_table_or_mismatched_summary_totals(self):
        for text in [TABLE.replace('1 nodes', '3 nodes'),
                     TABLE.replace('(64 bytes)', '(192 bytes)'),
                     TABLE.replace('All zones: 1 nodes (64 bytes)', 'All zones: unavailable'),
                     TABLE + ' 1 64 64.0 DuplicateClass Swift Example\n']:
            with self.subTest(text=text): self.assertFalse(self.capture(text)['valid'])

    def test_nonzero_retains_table_but_fails(self):
        self.assertFalse(self.capture(code=1)['valid'])

    def test_accepts_postdrain_observation_and_exact_final_frames(self):
        self.assertEqual(validate_rows(rows(), True)['frames'],2048000)

    def test_accepts_both_lengths_and_legacy_callback_totals(self):
        for candidate in [False, True]:
            for count in [1000, 2000]:
                r=rows()
                for row in r:
                    row['candidate']=candidate
                    if row['phase'] in ('drained','disposed','disposedLater'):
                        row['marker']['frames']=count*1024
                    row['modes']=dict(renderedSubmissions=count-1 if candidate else 0,
                        renderedCallbacks=count-1 if candidate else 0,
                        playedSubmissions=1 if candidate else count,playedCallbacks=1 if candidate else count)
                self.assertEqual(validate_rows(r,candidate,count)['frames'],count*1024)

    def test_rejects_active_heap_window_and_extra_mid_checkpoint(self):
        for change in [lambda r:r[2].update(nativePlaying=True),lambda r:r[1].update(phase='mid')]:
            r=rows();change(r)
            with self.assertRaises(ValueError):validate_rows(r,True)

    def test_rejects_loss_order_budget_error_and_missing_release(self):
        for change in [lambda r:r[-1]['marker'].update(frames=2047999),lambda r:r[-1]['marker'].update(errors=1),lambda r:r[-1]['marker'].update(interiorZeroFrames=1),
                       lambda r:r[1].update(ledgerPeak=196609),lambda r:r[-1].update(ledgerBytes=8192),
                       lambda r:r[1]['failures'].append('error'),lambda r:r.pop(2),
                       lambda r:r[2].update(generation=2),lambda r:r[-1]['modes'].update(playedCallbacks=0)]:
            r=rows();change(r)
            with self.assertRaises(ValueError):validate_rows(r,True)


if __name__=='__main__': unittest.main()
