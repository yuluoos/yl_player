import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch


class ProfilerLongTests(unittest.TestCase):
    def test_long_plan_keeps_all_unobserved_probes_when_resource_run_fails(self):
        from run_profiler_comparison import collect_long_off
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'new'
            def fail(path,*args,**kwargs):
                self.assertTrue(kwargs['long_lifetime_probes'])
                self.assertTrue(kwargs['profiler_off_lifetimes'])
                self.assertFalse(kwargs['lifetime_probes'])
                path.mkdir();return False
            with patch('run_profiler_comparison.collect',side_effect=fail):
                self.assertFalse(collect_long_off(out,'unused'))
            r=json.loads((out/'long-off.json').read_text());p=json.loads((out/'protocol.json').read_text())
            self.assertFalse(r['complete']);self.assertEqual(len(r['arm']['records']),16)
            self.assertTrue(all(x['status']=='not_observed' for x in r['arm']['records']))
            self.assertEqual(p['plannedAttempts'],100)
            self.assertEqual(p['windows'],[[1,'live'],[10,'disposed'],[50,'disposed'],[100,'disposed']])
            with self.assertRaises(FileExistsError):collect_long_off(out,'unused')

    def test_long_protocol_controls_once_and_reads_state_before_all_heap_windows(self):
        from run_profiler_comparison import collect_arm
        done=threading.Event();calls=[]
        windows=((1,'live'),(10,'disposed'),(50,'disposed'),(100,'disposed'))
        def capture(marker,tool,*args,**kwargs):
            calls.append((marker['attempt'],tool))
            r=dict(attempt=marker['attempt'],phase=marker['phase'],tool=tool,runId='run-1',pid=123,
                   status='captured',startedUs=marker['monotonicUs']+10,endedUs=marker['monotonicUs']+20)
            if tool=='profiler-control':r['control']=dict(after=False,vmIdentity={'pid':123,'groups':['app','system']})
            if (marker['attempt'],tool)==(100,'dart-memory'):done.set()
            return r
        def control(marker,output,mode):
            self.assertEqual(mode,'off' if marker['attempt']==1 else 'observe')
            return capture(marker,'profiler-control')
        def run(path,*args,**kwargs):
            path.mkdir();(path/'defines.json').write_text(json.dumps({'YL_RESOURCE_RUN_ID':'run-1'}))
            lines=[]
            for n,phase in windows:
                for edge,offset in (('begin',0),('end',100)):
                    m=dict(schemaVersion=2,protocol='long-cycle-v1',runId='run-1',pid=123,workload='playback',attempt=n,phase=phase,edge=edge,monotonicUs=n*1000+offset)
                    lines.append('YL_RESOURCE_CHECKPOINT='+json.dumps(m)+'\n')
            (path/'playback.log').write_text(''.join(lines))
            self.assertTrue(done.wait(3),'Monitor did not finish long windows')
            (path/'result.json').write_text(json.dumps({'observations':[dict(pid=123,outcome='passed')]*100,'endurance':{'protocolCompleted':True}}))
            return True
        with tempfile.TemporaryDirectory() as tmp:
            with patch('run_profiler_comparison.collect',side_effect=run),patch('run_profiler_comparison.capture_control',side_effect=control),patch('run_profiler_comparison.capture_probe',side_effect=capture),patch('run_profiler_comparison.EXECUTABLE',Path(tmp)/'missing'):
                result=collect_arm(Path(tmp)/'run','unused','off',long_cycles=True)
            self.assertTrue(result['complete'])
            self.assertEqual(calls,[(n,tool) for n,phase in windows for tool in ('profiler-control','heap','vmmap','dart-memory')])

    def test_long_mode_cannot_silently_run_on_or_without_long_resource_protocol(self):
        from run_profiler_comparison import collect_arm
        from run_resources import collect
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):collect_arm(Path(tmp)/'on','unused','on',long_cycles=True)
            for options in ({},dict(profile_cycles=True),dict(profile_cycles=True,long_lifetime_probes=True,memory_mapping=True)):
                with self.assertRaises(ValueError):collect(Path(tmp)/'invalid','unused',profiler_off_lifetimes=True,**options)

if __name__=='__main__':unittest.main()
