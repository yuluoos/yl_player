import unittest


def vm():return dict(type='VM',pid=123,startTime=1000,isolateGroups=[dict(id='groups/app')],systemIsolateGroups=[dict(id='groups/service')])
def flags(value):return dict(type='FlagList',flags=[dict(name='profiler',valueAsString=value)])


class ProfilerControlTests(unittest.TestCase):
    def test_observed_start_time_variation_does_not_invalidate_stable_group_identity(self):
        from profiler_control import control_profiler
        # The real macOS VM reported these values around one successful setFlag.
        before=dict(vm(),startTime=1791374942345);after=dict(vm(),startTime=1791374942344)
        replies=iter([before,flags('true'),{'type':'Success'},flags('true'),after])
        result=control_profiler(lambda m,p:next(replies),123,True)
        self.assertEqual(result['vmStartTimes'],[1791374942345,1791374942344])
        self.assertEqual(result['vmIdentity']['groups'],[{'id':'groups/app','kind':'application'},{'id':'groups/service','kind':'system'}])
        for invalid in ([],[{}],[dict(id='groups/service')],[None]):
            with self.assertRaises(ValueError):control_profiler(lambda m,p:dict(vm(),isolateGroups=invalid),123,None)

    def test_control_requires_actual_readback_and_keeps_initial_state(self):
        from profiler_control import control_profiler
        calls=[];results=iter([vm(),flags('true'),{'type':'Success'},flags('false'),vm()])
        def rpc(method,params):calls.append((method,params));return next(results)
        r=control_profiler(rpc,123,False)
        self.assertEqual((r['before'],r['after'],r['requested']),(True,False,False))
        self.assertEqual(r['vmStartTimes'],[1000,1000])
        self.assertEqual(calls[2],('setFlag',{'name':'profiler','value':'false'}))
        for observed in ('true','unknown',None):
            replies=iter([vm(),flags('true'),{'type':'Success'},flags(observed),vm()])
            with self.assertRaises(ValueError):control_profiler(lambda m,p:next(replies),123,False)

    def test_observation_is_read_only_and_missing_duplicate_or_restarted_vm_fails(self):
        from profiler_control import control_profiler
        calls=[]
        def rpc(method,params):calls.append(method);return vm() if method=='getVM' else flags('false')
        self.assertFalse(control_profiler(rpc,123,None)['after']);self.assertNotIn('setFlag',calls)
        for bad in (dict(type='FlagList',flags=[]),dict(type='FlagList',flags=flags('true')['flags']*2),{'type':'Sentinel'}):
            with self.assertRaises(ValueError):control_profiler(lambda m,p:vm() if m=='getVM' else bad,123,None)
        seq=iter([vm(),flags('true'),flags('true'),dict(vm(),isolateGroups=[dict(id='groups/restarted')])])
        with self.assertRaises(ValueError):control_profiler(lambda m,p:next(seq),123,None)

    def test_rpc_mutation_requires_opt_in_and_exact_profiler_value(self):
        import tempfile,time
        from pathlib import Path
        from memory_mapping import http_rpc
        with tempfile.TemporaryDirectory() as tmp:
            journal=Path(tmp)/'rpc.jsonl'
            plain=http_rpc('http://127.0.0.1:1/key=/',[],time.monotonic()+2,journal=journal)
            with self.assertRaises(ValueError):plain('setFlag',{'name':'profiler','value':'false'})
            controlled=http_rpc('http://127.0.0.1:1/key=/',[],time.monotonic()+2,journal=journal,allow_profiler_control=True)
            for params in ({'name':'pause_isolates_on_start','value':'true'}, {'name':'profiler','value':'bad'}, {'name':'profiler','value':'false','other':1}):
                with self.assertRaises(ValueError):controlled('setFlag',params)
            self.assertFalse(journal.exists(),'Rejected mutations must not start a request')

    def test_failed_pair_keeps_both_arms_and_all_planned_observers(self):
        import json,tempfile
        from pathlib import Path
        from unittest.mock import patch
        from run_profiler_comparison import collect_pair
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'new'
            def fail(path,*args,**kwargs):path.mkdir();return False
            with patch('run_profiler_comparison.collect',side_effect=fail),patch('run_profiler_comparison.capture_probe') as probe:
                self.assertFalse(collect_pair(out,'unused'));probe.assert_not_called()
            result=json.loads((out/'comparison.json').read_text())
            self.assertFalse(result['complete']);self.assertEqual(len(result['arms']),2)
            for arm in result['arms']:
                self.assertEqual(len(arm['records']),9)
                self.assertTrue(all(p['status']=='not_observed' for p in arm['records']))
            with self.assertRaises(FileExistsError):collect_pair(out,'unused')

if __name__=='__main__':unittest.main()
