import copy
import unittest
import tempfile
import plistlib
import subprocess
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch, MagicMock
from run_timed_video_activation import validate_run, collect, remove_thread_performance_checker, select_test_host
from test_collect_timed_video import observation


def sample():
    value=observation()
    value['rows'][0]['uptime']=10.0
    value['rows'][1].update(uptime=40.0, pid=123, dropEvents=[], activationEvents=[dict(name='NSApplicationDidBecomeActiveNotification',uptime=20.2)])
    return value, dict(exitCode=0, requested=20.0, returnedPID=123, active=True, sameOwnedPID=True), dict(exitCode=0, unchanged=True, ownedProcessExited=True)


class RunnerValidationTests(unittest.TestCase):
    def test_isolated_host_changes_only_host_paths_and_identity(self):
        original={'RunnerTests': {'TestHostPath':'/p/Profile/yl_player_example.app',
            'TestBundlePath':'__TESTHOST__/Contents/PlugIns/RunnerTests.xctest',
            'TestHostBundleIdentifier':'old.id',
            'BundleIdentifiersForCrashReportEmphasis':['old.id','old.id.RunnerTests'],
            'DependentProductPaths':['/p/Profile/yl_player_example.app','/p/Profile/yl_player_example.app/Contents/PlugIns/RunnerTests.xctest'],
            'EnvironmentVariables': {'KEEP':'yes'}}}
        config=copy.deepcopy(original)
        select_test_host(config,Path('/p/Profile/yl_player_example.app'),Path('/p/Profile/YLTimedProbe.app'),'owned.id')
        r=config['RunnerTests']
        self.assertEqual(r['TestHostPath'],'/p/Profile/YLTimedProbe.app')
        self.assertEqual(r['TestHostBundleIdentifier'],'owned.id')
        self.assertEqual(r['DependentProductPaths'],['/p/Profile/YLTimedProbe.app','/p/Profile/YLTimedProbe.app/Contents/PlugIns/RunnerTests.xctest'])
        self.assertEqual(r['BundleIdentifiersForCrashReportEmphasis'],['owned.id','old.id.RunnerTests'])
        self.assertEqual(r['EnvironmentVariables'],{'KEEP':'yes'})
        self.assertEqual(r['TestBundlePath'],original['RunnerTests']['TestBundlePath'])

    def test_remove_only_thread_checker_from_owned_manifest(self):
        config = {'RunnerTests': {
            'EnvironmentVariables': {'DYLD_INSERT_LIBRARIES': '/usr/lib/libRPAC.dylib', 'PERFC_ENABLE_PROFILE_MODE': '1', 'OTHER': 'kept'},
            'TestingEnvironmentVariables': {'DYLD_INSERT_LIBRARIES': '/a/libXCTestBundleInject.dylib:/b/libMainThreadChecker.dylib:/usr/lib/libRPAC.dylib', 'PERFC_SUPPRESS_SYSTEM_REPORTS': '1'}}}
        remove_thread_performance_checker(config)
        self.assertEqual(config['RunnerTests']['EnvironmentVariables'], {'OTHER': 'kept'})
        self.assertEqual(config['RunnerTests']['TestingEnvironmentVariables'], {'DYLD_INSERT_LIBRARIES': '/a/libXCTestBundleInject.dylib:/b/libMainThreadChecker.dylib'})
        original = copy.deepcopy(config)
        remove_thread_performance_checker(config)
        self.assertEqual(config, original)

    def test_helper_timeout_preserves_failure_and_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory); products=root/'products'; products.mkdir()
            (products/'Runner.xctestrun').write_bytes(plistlib.dumps({'RunnerTests': {'EnvironmentVariables': {}}}))
            args=SimpleNamespace(directory=root/'result', products=products, configuration='Debug', candidate=True, long=False)
            process=MagicMock(); process.poll.return_value=None; process.wait.return_value=-15
            def terminate(): process.poll.return_value=-15
            process.terminate.side_effect=terminate
            def run(command, **kwargs):
                if command[0]=='xcrun': return SimpleNamespace(returncode=0)
                if command[0]=='ps': return SimpleNamespace(stdout='',returncode=1)
                raise subprocess.TimeoutExpired(command,10)
            with patch('run_timed_video_activation.identities',return_value={'sourceHashes':{},'binaryHashes':{}}), \
                 patch('run_timed_video_activation.subprocess.run',side_effect=run), \
                 patch('run_timed_video_activation.subprocess.Popen',return_value=process), \
                 patch('run_timed_video_activation.read_rows',return_value=[{'phase':'playing','pid':123}]) as reads, \
                 patch('run_timed_video_activation.time.monotonic',side_effect=[0,1,2,3,12,13]):
                self.assertFalse(collect(args))
            self.assertTrue((args.directory/'run.json').exists())
            self.assertTrue((args.directory/'result.json').exists())
            self.assertTrue((args.directory/'activation.json').exists())
            process.terminate.assert_called_once()
            self.assertEqual(reads.call_count, 2, "Read initial ownership once, then final failure evidence; never reparse growing history while polling")

    def test_checker_removal_requires_runtime_proof(self):
        for value in [None, True]:
            o,a,r=sample();r['threadPerformanceCheckerRemoved']=True
            o['rows'][0]['runtimeDiagnostics']={'threadPerformanceCheckerLoaded': value}
            self.assertFalse(validate_run(o,a,r)['passed'])
        o,a,r=sample();r['threadPerformanceCheckerRemoved']=True
        for row in o['rows']: row['runtimeDiagnostics']={'threadPerformanceCheckerLoaded': False}
        self.assertTrue(validate_run(o,a,r)['passed'])

    def test_new_runs_cannot_use_legacy_missing_clock_evidence(self):
        o,a,r=sample(); r['audioClockProtocolRequired']=True
        self.assertFalse(validate_run(o,a,r)['passed'])

    def test_trace_gate_requires_matching_preplay_receipt(self):
        o,a,r=sample()
        r.update(traceGateRequired=True,traceGateToken='this-run')
        self.assertFalse(validate_run(o,a,r)['passed'])
        valid=dict(pid=123,token='this-run',recordingStartedUptime=5.,settledUptime=8.,stableSeconds=2.1,stableSamples=200,stableMaxGapSeconds=.012)
        r['traceGate']=valid
        self.assertTrue(validate_run(o,a,r)['passed'])
        for key,value in [('pid',999),('token','other-run'),('recordingStartedUptime',9.),('settledUptime',11.),('stableSeconds',1.),('stableMaxGapSeconds',.04),('stableSamples',0),('stableSamples',2)]:
            with self.subTest(key=key):
                r['traceGate']={**valid,key:value}
                self.assertFalse(validate_run(o,a,r)['passed'])

    def test_valid(self):
        o,a,r=sample();self.assertTrue(validate_run(o,a,r)['passed'])

    def test_required_external_evidence(self):
        for key, bad in [('exitCode',65),('unchanged',False),('ownedProcessExited',False)]:
            o,a,r=sample();r[key]=bad
            with self.subTest(key=key): self.assertFalse(validate_run(o,a,r)['passed'])
        for key,bad in [('exitCode',1),('returnedPID',999),('sameOwnedPID',False),('active',False),('requested',None)]:
            o,a,r=sample();a[key]=bad
            with self.subTest(key=key): self.assertFalse(validate_run(o,a,r)['passed'])
        o,a,r=sample();o['rows'][1]['activationEvents']=[]
        self.assertFalse(validate_run(o,a,r)['passed'])
        o,a,r=sample();o['rows'].pop();self.assertFalse(validate_run(o,a,r)['passed'])

    def test_classification_and_truncation(self):
        o,a,r=sample();o['rows'][1].update(applicationDrops=3,dropEvents=[dict(uptime=19,count=1),dict(uptime=21,count=2)])
        result=validate_run(o,a,r);self.assertEqual(result['dropClassification'],dict(before=1,after=2,complete=True))
        o['rows'][1]['dropEvents'].pop();self.assertFalse(validate_run(o,a,r)['dropClassification']['complete'])

    def test_activation_must_be_in_interval(self):
        for uptime in [19.9,41.0]:
            o,a,r=sample();o['rows'][1]['activationEvents'][0]['uptime']=uptime
            self.assertFalse(validate_run(o,a,r)['passed'])

if __name__=='__main__': unittest.main()
