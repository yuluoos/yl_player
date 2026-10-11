import json
import argparse
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from run_timed_video_trace import RowTail, check_recorder, revoke_gate
import run_timed_video_trace as trace

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

class SystemDropTriggerTests(unittest.TestCase):
    def test_drop_without_ready_wait_preserves_previous_and_current_rows(self):
        detector=trace.SystemDropTrigger()
        before={'phase':'playing','uptime':10,'systemMetrics':{'dropped':3}}
        after={'phase':'playing','uptime':11,'systemMetrics':{'dropped':4}}
        self.assertIsNone(detector.observe(before))
        event=detector.observe(after)
        self.assertEqual(event,{'before':before,'after':after,'count':1})
        self.assertIsNone(detector.observe(after))

    def test_missing_reset_and_disposal_metrics_do_not_invent_a_drop(self):
        detector=trace.SystemDropTrigger()
        for row in ({'phase':'playing'},
                    {'phase':'playing','systemMetrics':{'dropped':2}},
                    {'phase':'disposed','systemMetrics':{'dropped':10}},
                    {'phase':'playing','systemMetrics':{'dropped':0}},
                    {'phase':'playing','systemMetrics':{'dropped':float('nan')}},
                    {'phase':'playing','systemMetrics':{'dropped':-1}}):
            self.assertIsNone(detector.observe(row))
        self.assertEqual(detector.observe({'phase':'playing','systemMetrics':{'dropped':1}})['count'],1)

    def test_system_drop_does_not_truncate_ready_recovery(self):
        row={'nativeDiagnostics':{'blockedSince':10,'backpressureEvents':[]}}
        drop={'count':1}
        self.assertIsNone(trace.capture_event(row,.06,drop))
        event={'firstRejectedUptime':10,'enqueueBeganUptime':10.119,'enqueueReturnedUptime':10.1191}
        row['nativeDiagnostics']['blockedSince']=None
        row['nativeDiagnostics']['backpressureEvents']=[event]
        self.assertEqual(trace.capture_event(row,.06,drop),{'kind':'completedReadyWait','event':event,'systemDrop':drop})
        row['nativeDiagnostics']['backpressureEvents']=[]
        self.assertEqual(trace.capture_event(row,.06,drop),{'kind':'systemDrop','systemDrop':drop})
        self.assertIsNone(trace.capture_event({},.06,drop))
        self.assertIsNone(trace.capture_event(row,.06))

    def test_new_pending_wait_during_drop_tail_restarts_tail_after_recovery(self):
        trigger={'kind':'systemDrop','detectedUptime':10}
        ready={'nativeDiagnostics':{'blockedSince':None}}
        blocked={'nativeDiagnostics':{'blockedSince':10.1}}
        self.assertFalse(trace.capture_tail_complete(trigger,ready,10.1))
        self.assertFalse(trace.capture_tail_complete(trigger,blocked,10.3))
        self.assertFalse(trace.capture_tail_complete(trigger,ready,10.5))
        self.assertFalse(trace.capture_tail_complete(trigger,ready,10.7))
        self.assertTrue(trace.capture_tail_complete(trigger,ready,10.76))
        self.assertFalse(trace.capture_tail_complete(trigger,{},11))

class CompleteIntervalTests(unittest.TestCase):
    def test_lower_diagnostic_threshold_keeps_complete_event_requirement(self):
        event={'firstRejectedUptime':10,'enqueueBeganUptime':10.035,'enqueueReturnedUptime':10.0351}
        row={'nativeDiagnostics':{'backpressureEvents':[event]}}
        self.assertIsNone(trace.completed_ready_event(row))
        self.assertEqual(trace.completed_ready_event(row,threshold_seconds=.03),event)
        del event['enqueueReturnedUptime']
        self.assertIsNone(trace.completed_ready_event(row,threshold_seconds=.03))

    def test_diagnostic_threshold_must_be_positive_and_finite(self):
        for value in ('0','-1','nan','inf','-inf','invalid'):
            with self.assertRaises(argparse.ArgumentTypeError):trace.positive_milliseconds(value)
        self.assertEqual(trace.positive_milliseconds('30'),30)

    def test_pending_wait_does_not_stop_recording_before_recovery(self):
        row={'uptime':20, 'nativeDiagnostics':{'blockedSince':10,'backpressureEvents':[]}}
        self.assertIsNone(trace.completed_ready_event(row))

    def test_only_a_complete_long_wait_can_trigger(self):
        event={'firstRejectedUptime':10,'enqueueBeganUptime':10.119}
        row={'nativeDiagnostics':{'backpressureEvents':[event]}}
        self.assertIsNone(trace.completed_ready_event(row))
        event['enqueueReturnedUptime']=10.1191
        self.assertEqual(trace.completed_ready_event(row),event)
        event['enqueueBeganUptime']=10.01
        self.assertIsNone(trace.completed_ready_event(row))

    def test_system_trace_only_retains_owned_pid_gate_and_window(self):
        command=trace.recording_command(41,'run-token',Path('/tmp/test.trace'),1320,True)
        self.assertNotIn('--instrument',command)
        self.assertEqual(command[command.index('--attach')+1],'41')
        self.assertEqual(command[command.index('--notify-tracing-started')+1],'run-token')
        self.assertEqual(command[command.index('--window')+1],'10s')
        legacy=trace.recording_command(41,'run-token',Path('/tmp/test.trace'),45,False)
        self.assertIn('Core Animation Server',legacy)
        self.assertIn('Display',legacy)

    def test_system_scope_does_not_attach_to_player(self):
        command=trace.recording_command(41,'run-token',Path('/tmp/test.trace'),1320,True,all_processes=True)
        self.assertIn('--all-processes',command)
        self.assertNotIn('--attach',command)
        self.assertNotIn('41',command)
        self.assertEqual(command[command.index('--notify-tracing-started')+1],'run-token')
        self.assertEqual(command[command.index('--window')+1],'10s')

if __name__=='__main__':unittest.main()
