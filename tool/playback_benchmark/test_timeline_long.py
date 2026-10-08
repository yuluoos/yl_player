import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch


class TimelineLongTests(unittest.TestCase):
    def test_failed_long_run_retains_sixteen_probes_and_no_stack_logging_protocol(self):
        from run_timeline_comparison import collect_long_off
        def fail(path,*args,**kwargs):
            self.assertTrue(kwargs['long_lifetime_probes'])
            self.assertTrue(kwargs['timeline_off_lifetimes'])
            self.assertFalse(kwargs['profiler_off_lifetimes'])
            path.mkdir();return False
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'new'
            with patch('run_profiler_comparison.collect',side_effect=fail):
                self.assertFalse(collect_long_off(out,'unused'))
            r=json.loads((out/'long-off.json').read_text());p=json.loads((out/'protocol.json').read_text())
            self.assertFalse(r['complete']);self.assertEqual(len(r['arm']['records']),16)
            self.assertTrue(all(x['status']=='not_observed' for x in r['arm']['records']))
            self.assertFalse(p['stackLogging']);self.assertFalse(p['clearTimeline'])
            self.assertEqual(p['plannedAttempts'],100);self.assertEqual(p['minimumObservationSeconds'],600)
            with self.assertRaises(FileExistsError):collect_long_off(out,'unused')
            with patch.dict('os.environ',{'MallocStackLogging':'full'}):
                with self.assertRaises(ValueError):collect_long_off(Path(tmp)/'bad','unused')

    def test_all_four_long_windows_verify_disabled_streams_before_memory_probes(self):
        from run_profiler_comparison import collect_arm
        done=threading.Event();calls=[]
        windows=((1,'live'),(10,'disposed'),(50,'disposed'),(100,'disposed'))
        def capture(marker,tool,*args,**kwargs):
            calls.append((marker['attempt'],tool))
            r=dict(attempt=marker['attempt'],phase=marker['phase'],tool=tool,runId='run-1',pid=123,
                   status='captured',startedUs=marker['monotonicUs']+10,endedUs=marker['monotonicUs']+20)
            if tool=='timeline-control':r['control']=dict(after=dict(recordedStreams=[],recorderName='Ring'),vmIdentity={'pid':123,'groups':['app','system']})
            if (marker['attempt'],tool)==(100,'dart-memory'):done.set()
            return r
        def control(marker,output,mode):
            self.assertEqual(mode,'off' if marker['attempt']==1 else 'observe')
            return capture(marker,'timeline-control')
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
            with patch('run_profiler_comparison.collect',side_effect=run),patch('run_timeline_comparison.capture_timeline',side_effect=control),patch('run_profiler_comparison.capture_probe',side_effect=capture),patch('run_profiler_comparison.EXECUTABLE',Path(tmp)/'missing'):
                result=collect_arm(Path(tmp)/'run','unused','off',long_cycles=True,timeline_off=True)
            self.assertTrue(result['complete'])
            self.assertEqual(calls,[(n,tool) for n,phase in windows for tool in ('timeline-control','heap','vmmap','dart-memory')])

    def test_enabled_timeline_cannot_admit_following_heap_or_complete_run(self):
        from run_profiler_comparison import collect_arm
        seen=threading.Event()
        def control(m,*args):
            seen.set()
            return dict(attempt=1,phase='live',tool='timeline-control',runId='run-1',pid=123,status='captured',startedUs=1010,endedUs=1020,
                control=dict(after=dict(recordedStreams=['GC'],recorderName='Ring'),vmIdentity={'pid':123}))
        def run(path,*args,**kwargs):
            path.mkdir();(path/'defines.json').write_text(json.dumps({'YL_RESOURCE_RUN_ID':'run-1'}))
            m=dict(schemaVersion=2,protocol='long-cycle-v1',runId='run-1',pid=123,workload='playback',attempt=1,phase='live',edge='begin',monotonicUs=1000)
            (path/'playback.log').write_text('YL_RESOURCE_CHECKPOINT='+json.dumps(m)+'\n')
            self.assertTrue(seen.wait(3));return False
        with tempfile.TemporaryDirectory() as tmp:
            with patch('run_profiler_comparison.collect',side_effect=run),patch('run_timeline_comparison.capture_timeline',side_effect=control):
                result=collect_arm(Path(tmp)/'run','unused','off',long_cycles=True,timeline_off=True)
            self.assertFalse(result['complete']);self.assertTrue(result['errors'])
            self.assertTrue(all(r['status']=='not_observed' for r in result['records'] if r['tool']!='timeline-control'))

    def test_long_timeline_mode_rejects_short_or_mixed_protocols(self):
        from run_profiler_comparison import collect_arm
        from run_resources import collect
        with tempfile.TemporaryDirectory() as tmp:
            for options in ({},dict(long_cycles=True)):
                with self.assertRaises(ValueError):collect_arm(Path(tmp)/'bad','unused','on',timeline_off=True,**options)
            for options in ({},dict(profile_cycles=True,long_lifetime_probes=True,profiler_off_lifetimes=True),dict(profile_cycles=True,long_lifetime_probes=True,timeline_control=True)):
                with self.assertRaises(ValueError):collect(Path(tmp)/'bad','unused',timeline_off_lifetimes=True,**options)

if __name__=='__main__':unittest.main()
