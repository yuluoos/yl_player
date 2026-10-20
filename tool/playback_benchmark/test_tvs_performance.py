import copy,json,tempfile,unittest
from pathlib import Path
from unittest.mock import patch
from contextlib import ExitStack
import run_tvs_performance as collector
from run_tvs_performance import parse_log,verify_player_dependencies
class TVSPerformanceTests(unittest.TestCase):
    def test_actual_receipt_and_every_phase_required(self):
        receipt=dict(run='owned',completed=True,ownedCleanupCompleted=True,providerAsyncCleanupVerified=True)
        row=dict(run='owned',boundary='public-first-frame-future-observed',channelIndex=0,sourceAttempts=1,physicalOutputVerified=False,omitted=0,
            spans=[dict(phase=p,startedUs=1,endedUs=10,outcome='returned') for p in ['kernelFirstFrame','sourceAttempt','switchChannel','firstFrameObserved']])
        with tempfile.TemporaryDirectory() as tmp:
            log=Path(tmp)/'log'
            def write(r):log.write_text('P08_SWITCH='+json.dumps(r)+'\nP05_RECEIPT '+json.dumps(receipt)+'\n')
            write(row);self.assertTrue(parse_log(log)['complete'])
            for key,value in [('omitted',1),('spans',row['spans'][1:]),('incomplete',True)]:
                bad=copy.deepcopy(row);bad[key]=value;write(bad);self.assertFalse(parse_log(log)['complete'])
            bad=copy.deepcopy(row);bad['run']='other';write(bad)
            with self.assertRaises(ValueError):parse_log(log)
    def test_no_current_player_dependency_may_point_to_other_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);tvs=root/'tvs';player=root/'player';(tvs/'.dart_tool').mkdir(parents=True)
            packages=[dict(name=name,rootUri=str(player/'packages'/name)) for name in ['yl_player','yl_player_apple','yl_player_android','yl_player_media_core','yl_player_platform_interface','yl_player_source_resolver']]
            path=tvs/'.dart_tool/package_config.json';path.write_text(json.dumps(dict(packages=packages)))
            self.assertEqual(len(verify_player_dependencies(tvs,player)),64)
            packages[0]['rootUri']=str(root/'different');path.write_text(json.dumps(dict(packages=packages)))
            with self.assertRaises(ValueError):verify_player_dependencies(tvs,player)

    def test_missing_final_host_binary_cannot_report_success(self):
        with tempfile.TemporaryDirectory() as tmp, ExitStack() as stack:
            root=Path(tmp);out=root/'out'
            for name,value in [('tvs_identity',{}),('source_identity',{}),('verify_player_dependencies','a'*64),('run_logged',0),('parse_log',{'complete':True})]:
                stack.enter_context(patch.object(collector,name,return_value=value))
            stack.enter_context(patch.object(collector.subprocess,'check_output',return_value='a'*40))
            self.assertFalse(collector.collect(out,root/'tvs',root/'player','flutter'))
            receipt=json.loads((out/'result.json').read_text())
            self.assertFalse(receipt['complete'])
            self.assertEqual(receipt['failure'],'collection-incomplete')
