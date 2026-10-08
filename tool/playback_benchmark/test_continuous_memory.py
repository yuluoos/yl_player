import copy
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch
from test_continuous import rows


class ContinuousMemoryTests(unittest.TestCase):
    def test_partial_line_retried_but_malformed_complete_rejected(self):
        from run_continuous_memory import read_rows
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'log';first=json.dumps(rows()[0])
            p.write_text('noise\nYL_CONTINUOUS='+first+'\nYL_CONTINUOUS={')
            self.assertEqual(read_rows(p,'continuous-test'),rows()[:1])
            p.write_text('YL_CONTINUOUS={bad}\n')
            with self.assertRaises(ValueError):read_rows(p,'continuous-test')
            p.write_text('YL_CONTINUOUS='+first.replace('"pid": 42','"pid": 42, "pid": 42')+'\n')
            with self.assertRaises(ValueError):read_rows(p,'continuous-test')

    def test_exact_clock_session_and_pid_window(self):
        from run_continuous_memory import qualify
        data=rows();p=dict(attempt=1,phase='live',tool='heap',runId='continuous-test',pid=42,
            status='captured',startedUs=2,endedUs=49000000)
        self.assertTrue(qualify(p,data,'continuous-test'))
        self.assertFalse(qualify(p,data[:10],'continuous-test'))
        self.assertFalse(qualify(dict(p,endedUs=50000002),data,'continuous-test'))
        for field,value in [('pid',43),('runId','foreign')]:
            with self.assertRaises(ValueError):qualify(dict(p,**{field:value}),data,'continuous-test')
        data[10]['sessionId']='new'
        with self.assertRaises(ValueError):qualify(p,data,'continuous-test')

    def test_failed_collect_preserves_all_twelve_planned_records_and_protocol(self):
        from run_continuous_memory import collect_memory
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/'out'
            with patch('run_continuous_memory.collect',return_value=False):
                self.assertFalse(collect_memory(out,'flutter'))
            r=json.loads((out/'memory-probes.json').read_text())
            self.assertEqual(len(r['records']),12)
            self.assertTrue(all(x['status']=='not_observed' for x in r['records']))
            self.assertFalse(r['complete'])
            protocol=json.loads((out/'protocol.json').read_text())
            self.assertFalse(protocol['stackLogging'])
            self.assertEqual(protocol['tickWindows'],[[0,10],[120,130],[230,240]])
            with self.assertRaises(FileExistsError):collect_memory(out,'flutter')

    def test_order_identity_and_complete_qualification(self):
        from run_continuous_memory import collect_memory
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/'out';done=threading.Event();calls=[]
            identity=dict(pid=42,groups=[dict(id='g',kind='application'),dict(id='s',kind='system')])
            def fake_collect(p,flutter,**kwargs):
                self.assertTrue(kwargs['memory_diagnostics']);p.mkdir()
                (p/'defines.json').write_text(json.dumps(dict(YL_RESOURCE_RUN_ID='continuous-test')))
                (p/'playback.log').write_text(''.join('YL_CONTINUOUS='+json.dumps(r)+'\n' for r in rows()))
                done.wait(5)
                (p/'result.json').write_text(json.dumps(dict(complete=True)))
                return True
            def capture(m,p,tool=None,**kwargs):
                tool=tool or 'timeline-control';calls.append((m['attempt'],tool))
                start={1:1,2:600000001,3:1150000001}[m['attempt']]
                r=dict(m,tool=tool,status='captured',startedUs=start+1,endedUs=start+100)
                if tool=='timeline-control':r['control']=dict(profilerAfter=dict(after=False),after=dict(recordedStreams=[]),vmIdentity=identity)
                if tool=='dart-memory':r['memory']=dict(scope='application-and-system-isolate-groups',groups=[dict(g,memory={}) for g in identity['groups']],forcedGC=False)
                if len(calls)==12:done.set()
                return r
            with patch('run_continuous_memory.collect',side_effect=fake_collect),patch('run_continuous_memory.capture_timeline',side_effect=lambda m,p,mode:capture(m,p)),patch('run_continuous_memory.capture_probe',side_effect=lambda m,t,p,**kw:capture(m,p,t,**kw)):
                self.assertTrue(collect_memory(out,'flutter'))
            r=json.loads((out/'memory-probes.json').read_text())
            self.assertEqual(calls,[(n,t) for n in (1,2,3) for t in ('timeline-control','heap','vmmap','dart-memory')])
            self.assertTrue(all(x['qualified'] for x in r['records']))

    def test_vm_groups_must_match_control_and_timeline_must_be_off(self):
        from run_continuous_memory import verify_control, verify_memory
        identity=dict(pid=42,groups=[dict(id='g',kind='application')])
        c=dict(status='captured',control=dict(profilerAfter=dict(after=False),after=dict(recordedStreams=[]),vmIdentity=identity))
        self.assertEqual(verify_control(c,42,None),identity)
        bad=copy.deepcopy(c);bad['control']['after']['recordedStreams']=['Dart']
        with self.assertRaises(ValueError):verify_control(bad,42,None)
        with self.assertRaises(ValueError):verify_control(c,42,dict(identity,groups=[]))
        m=dict(status='captured',memory=dict(scope='application-and-system-isolate-groups',forcedGC=False,groups=[dict(id='other',kind='application')]))
        with self.assertRaises(ValueError):verify_memory(m,identity)

    def test_cadence_failure_retained_without_suppressing_later_diagnostics(self):
        from run_continuous_memory import read_rows
        from continuous import summarize_continuous
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'log';data=rows();data[0]['positionUs']=2054000;data[1]['positionUs']=5279000
            p.write_text(''.join('YL_CONTINUOUS='+json.dumps(r)+'\n' for r in data))
            observed=read_rows(p,'continuous-test')
            self.assertEqual(observed,data)
            self.assertFalse(summarize_continuous(observed,'continuous-test')['complete'])
            self.assertIn('progress-or-sampling-gap',summarize_continuous(observed,'continuous-test')['reasons'])

    def test_monitor_error_is_durable_while_collector_still_running(self):
        from run_continuous_memory import collect_memory
        with tempfile.TemporaryDirectory() as d:
            out=Path(d)/'out';observed=[]
            def fake_collect(p,flutter,**kwargs):
                p.mkdir();(p/'defines.json').write_text(json.dumps(dict(YL_RESOURCE_RUN_ID='continuous-test')))
                (p/'playback.log').write_text('YL_CONTINUOUS={bad}\n')
                import time
                deadline=time.monotonic()+.8
                while time.monotonic()<deadline:
                    errors=json.loads((out/'memory-probes.json').read_text())['errors']
                    if errors:observed.extend(errors);break
                    time.sleep(.02)
                return False
            with patch('run_continuous_memory.collect',side_effect=fake_collect):
                self.assertFalse(collect_memory(out,'flutter'))
            self.assertTrue(observed)
