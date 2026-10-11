import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from run_timed_video_trace import RowTail, check_recorder, revoke_gate

class TraceTailTests(unittest.TestCase):
    def test_growing_capture_never_reparses_old_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'rows';p.write_text('{"phase":"playing","n":1}\n')
            tail=RowTail(p)
            with patch('json.loads',wraps=json.loads) as decode:
                self.assertEqual(tail.poll()['n'],1)
                for _ in range(20):self.assertEqual(tail.poll()['n'],1)
                self.assertEqual(decode.call_count,1,'Polling must not reparse growing capture history')

    def test_partial_write_is_not_an_incident_until_complete(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory)/'rows';tail=RowTail(p)
            self.assertIsNone(tail.poll())
            p.write_text('{"n":1}\n{"n":')
            self.assertEqual(tail.poll()['n'],1)
            with p.open('a') as f:f.write('2}\n')
            self.assertEqual(tail.poll()['n'],2)

class RecorderLifecycleTests(unittest.TestCase):
    def test_failed_receipt_write_does_not_prevent_cleanup_or_keep_gate(self):
        with tempfile.TemporaryDirectory() as directory:
            p=Path(directory); (p/'trace-started.json').write_text('{}')
            errors=['recorder exited']
            with patch.object(Path,'write_text',side_effect=OSError('disk full')):
                revoke_gate(p,'run',errors)
            self.assertFalse((p/'trace-started.json').exists())
            self.assertTrue(any('disk full' in error for error in errors))

    def test_dead_recorder_cannot_release_gate_even_with_queued_notification(self):
        for code in (0, 1):
            with self.assertRaises(RuntimeError):
                check_recorder(code, now=10, started=5, settled=False, stop_sent=False, duration=45)

    def test_time_limit_cannot_expire_while_gate_is_still_pending(self):
        with self.assertRaises(RuntimeError):
            check_recorder(None, now=49, started=5, settled=False, stop_sent=False, duration=45)

    def test_unexpected_exit_fails_after_playback_too(self):
        with self.assertRaises(RuntimeError):
            check_recorder(0, now=10, started=5, settled=True, stop_sent=False, duration=45)
        with self.assertRaises(RuntimeError):
            check_recorder(1, now=60, started=5, settled=True, stop_sent=True, duration=45)
        check_recorder(0, now=60, started=5, settled=True, stop_sent=False, duration=45)
        check_recorder(0, now=10, started=5, settled=True, stop_sent=True, duration=45)
        check_recorder(None, now=10, started=5, settled=False, stop_sent=False, duration=45)

if __name__=='__main__':unittest.main()
