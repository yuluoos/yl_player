import copy
import unittest
import tempfile
import plistlib
import subprocess
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch, MagicMock
from run_timed_video_activation import validate_run, collect
from test_collect_timed_video import observation


def sample():
    value=observation()
    value['rows'][0]['uptime']=10.0
    value['rows'][1].update(uptime=40.0, pid=123, dropEvents=[], activationEvents=[dict(name='NSApplicationDidBecomeActiveNotification',uptime=20.2)])
    return value, dict(exitCode=0, requested=20.0, returnedPID=123, active=True, sameOwnedPID=True), dict(exitCode=0, unchanged=True, ownedProcessExited=True)


class RunnerValidationTests(unittest.TestCase):
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
                 patch('run_timed_video_activation.read_rows',return_value=[{'phase':'playing','pid':123}]), \
                 patch('run_timed_video_activation.time.monotonic',side_effect=[0,1,12,13]):
                self.assertFalse(collect(args))
            self.assertTrue((args.directory/'run.json').exists())
            self.assertTrue((args.directory/'result.json').exists())
            self.assertTrue((args.directory/'activation.json').exists())
            process.terminate.assert_called_once()

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
