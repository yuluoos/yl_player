"""Real owned-process failure tests; no SDK or device is used."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from types import SimpleNamespace
from tool import run_android_integration as runner_module

ROOT = Path(__file__).resolve().parent


class AndroidIntegrationRunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='yl-runner-')
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        self.env = dict(os.environ, TMPDIR=str(self.path),
                        PATH=str(self.path) + os.pathsep + os.environ['PATH'],
                        YL_ANDROID_DEVICE_ID='owned-5580',
                        YL_ADB=str(self.path/'adb'), YL_FLUTTER=str(self.path/'flutter'),
                        YL_ANDROID_RUN_TIMEOUT_SECONDS='3',
                        YL_ANDROID_ADB_TIMEOUT_SECONDS='1',
                        YL_ANDROID_CLEANUP_TIMEOUT_SECONDS='2',
                        CALLS=str(self.path/'calls'), CASE='normal')
        self.executable('adb', '''
args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as f:f.write(json.dumps(args)+'\\n')
case=os.environ['CASE']
if case=='slow-preflight':time.sleep(.12)
if case=='restore-hang' and 'start' in args:
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    while True:time.sleep(.05)
if (case=='preflight' and 'getprop' in args) or (case=='failure-log' and args[-2:]==['logcat','-d'] and pathlib.Path(os.environ['CALLS']+'.failed').exists()):
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    while True:time.sleep(.05)
if 'getprop' in args:print('24')
if case=='home-fail' and 'KEYCODE_HOME' in args:sys.exit(23)
''')
        self.executable('flutter', '''
case=os.environ['CASE']
if case=='failure-log':
    pathlib.Path(os.environ['CALLS']+'.failed').write_text('yes');sys.exit(17)
if case in ['home-fail','restore-hang']:
    print('YL_ANDROID_LIFECYCLE_BACKGROUND_READY',flush=True)
    while True:time.sleep(.05)
if case in ['child','leader-exit']:
    child=subprocess.Popen([sys.executable,'-c','import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'])
    pathlib.Path(os.environ['CALLS']+'.pid').write_text(str(child.pid))
    time.sleep(.1)
    if case=='leader-exit':sys.exit(0)
    signal.signal(signal.SIGTERM,signal.SIG_IGN)
    while True:time.sleep(.05)
''')

    def executable(self, name, body):
        p=self.path/name
        p.write_text('#!'+sys.executable+'\nimport os,sys,time,signal,subprocess,pathlib,json\n'+body)
        p.chmod(0o755)

    def run_case(self, case, signum=None):
        env=dict(self.env,CASE=case)
        started=time.monotonic()
        p=subprocess.Popen(['sh',str(ROOT/'run_android_integration.sh'),'suite with spaces.dart'],
                           env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
        timed_out=False
        try:
            if signum is not None:
                deadline=time.monotonic()+3
                while not (self.path/'calls.pid').exists() and time.monotonic()<deadline:
                    time.sleep(.01)
                self.assertTrue((self.path/'calls.pid').exists())
                time.sleep(.15)
                os.kill(p.pid,signum)
            try:stdout,stderr=p.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                timed_out=True;os.killpg(p.pid,signal.SIGKILL);stdout,stderr=p.communicate(timeout=2)
        finally:
            if p.poll() is None:
                try:os.killpg(p.pid,signal.SIGKILL)
                except ProcessLookupError:pass
            if p.poll() is None:
                p.wait(timeout=2)
            if p.stdout is not None:p.stdout.close()
            if p.stderr is not None:p.stderr.close()
            child=self.path/'calls.pid'
            if child.exists():
                # Last-resort fixture cleanup only; assertions happen before this cleanup.
                self.addCleanup(self.kill_fixture_pid,int(child.read_text()))
        self.assertFalse(timed_out,'runner exceeded bounded failure deadline')
        self.assertLess(time.monotonic()-started,8)
        receipt_lines=[l for l in stderr.splitlines() if l.startswith('Android test receipt: ')]
        self.assertEqual(len(receipt_lines),1,stdout+stderr)
        receipt=json.loads(Path(receipt_lines[0].split(': ',1)[1]).read_text())
        return p.returncode,receipt

    @staticmethod
    def kill_fixture_pid(pid):
        try:os.kill(pid,signal.SIGKILL)
        except ProcessLookupError:pass

    def assert_child_stopped(self):
        pid=int((self.path/'calls.pid').read_text())
        result=subprocess.run(['ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
        self.assertTrue(result.returncode!=0 or result.stdout.strip().startswith('Z'),result.stdout)

    def test_hung_device_preflight_is_bounded_and_never_starts_flutter(self):
        code,r=self.run_case('preflight')
        self.assertEqual(code,124)
        self.assertFalse(any(c['kind']=='flutter' for c in r['commands']))
        self.assertTrue(r['cleanup']['complete'])

    def test_failed_test_keeps_exit_code_when_failure_logcat_hangs(self):
        code,r=self.run_case('failure-log')
        self.assertEqual(code,17)
        self.assertTrue(any(c['kind']=='failure-logcat' and c['timedOut'] for c in r['commands']))
        self.assertTrue(r['cleanup']['complete'])

    def test_deadline_kills_owned_term_ignoring_descendant(self):
        code,r=self.run_case('child')
        self.assertEqual(code,124)
        self.assert_child_stopped()
        self.assertTrue(r['cleanup']['complete'])

    def test_successful_leader_does_not_leave_child_running(self):
        code,r=self.run_case('leader-exit')
        self.assertEqual(code,0)
        self.assert_child_stopped()
        self.assertTrue(r['cleanup']['complete'])

    def test_failed_background_action_stops_test_and_attempts_restore(self):
        code,r=self.run_case('home-fail')
        self.assertEqual(code,23)
        calls=[json.loads(l) for l in (self.path/'calls').read_text().splitlines()]
        self.assertEqual(sum('KEYCODE_HOME' in x for x in calls),1)
        self.assertTrue(any('start' in x for x in calls))
        self.assertTrue(all(x[:2]==['-s','owned-5580'] for x in calls))


    def test_preflight_commands_share_one_execution_deadline(self):
        self.env['YL_ANDROID_RUN_TIMEOUT_SECONDS']='0.32'
        code,r=self.run_case('slow-preflight')
        self.assertEqual(code,124)
        self.assertFalse(any(c['kind']=='flutter' for c in r['commands']))
        self.assertTrue(r['cleanup']['complete'])

    def test_restore_is_bounded_and_cannot_replace_primary_timeout(self):
        code,r=self.run_case('restore-hang')
        self.assertEqual(code,124)
        self.assertFalse(r['cleanup']['foregroundRestored'])
        self.assertTrue(any(c['kind']=='restore' and c['timedOut'] for c in r['commands']))
        self.assertTrue(r['cleanup']['complete'])

    def test_signals_cleanup_owned_group_without_touching_other_process(self):
        other=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'],start_new_session=True)
        try:
            self.env['YL_ANDROID_RUN_TIMEOUT_SECONDS']='5'
            for signum in [signal.SIGTERM,signal.SIGINT,signal.SIGHUP]:
                with self.subTest(signal=signum):
                    (self.path/'calls.pid').unlink(missing_ok=True)
                    code,r=self.run_case('child',signum)
                    self.assertEqual(code,128+signum)
                    self.assertEqual(r['signal'],signum)
                    self.assert_child_stopped()
                    self.assertTrue(r['cleanup']['complete'])
                    self.assertIsNone(other.poll())
        finally:
            other.terminate();other.wait(timeout=2)

    def test_normal_exit_retains_suite_argument_and_device_identity(self):
        code,r=self.run_case('normal')
        self.assertEqual(code,0)
        command=next(c['command'] for c in r['commands'] if c['kind']=='flutter')
        self.assertEqual(command[2],'suite with spaces.dart')
        self.assertEqual(command[command.index('-d')+1],'owned-5580')
        self.assertTrue(r['cleanup']['complete'])

    def test_configuration_cannot_expand_production_deadlines(self):
        for name,value in [('YL_ANDROID_RUN_TIMEOUT_SECONDS','601'),
                           ('YL_ANDROID_ADB_TIMEOUT_SECONDS','16'),
                           ('YL_ANDROID_CLEANUP_TIMEOUT_SECONDS','31'),
                           ('YL_ANDROID_RUN_TIMEOUT_SECONDS','nan')]:
            with self.subTest(name=name,value=value):
                env=dict(self.env,**{name:value})
                result=subprocess.run(['sh',str(ROOT/'run_android_integration.sh'),'suite.dart'],
                                      env=env,capture_output=True,text=True,timeout=2)
                self.assertEqual(result.returncode,2)
                self.assertFalse((self.path/'calls').exists())


    def test_retired_group_identity_is_never_signalled_after_pid_reuse(self):
        runner=runner_module.Runner.__new__(runner_module.Runner)
        runner.processes=[(SimpleNamespace(pid=123456,poll=lambda:0),{})]
        runner.cleanup_errors=[]
        exists=False
        with mock.patch.object(runner_module,'group_exists',side_effect=lambda _:exists), mock.patch.object(runner_module.os,'killpg') as kill:
            self.assertTrue(runner.stop_groups(time.monotonic()+.05))
            exists=True  # The old group has ended; this identifier now belongs elsewhere.
            self.assertTrue(runner.stop_groups(time.monotonic()+.05))
            kill.assert_not_called()


    def test_permission_denied_does_not_prove_group_absence(self):
        with mock.patch.object(runner_module.os,'killpg',side_effect=PermissionError):
            self.assertTrue(runner_module.group_exists(123456))

    def test_successful_test_cannot_hide_incomplete_cleanup(self):
        with mock.patch.dict(os.environ,self.env), mock.patch.object(tempfile,'tempdir',str(self.path)), mock.patch.object(runner_module.Runner,'stop_groups',return_value=False):
            runner=runner_module.Runner('suite.dart',[])
            self.assertEqual(runner.run(),70)
            receipt=json.loads(runner.log.with_name(runner.log.name+'.receipt.json').read_text())
            self.assertEqual(receipt['primaryExitCode'],0)
            self.assertFalse(receipt['cleanup']['complete'])

    def test_invalid_device_api_does_not_launch_flutter(self):
        self.executable('adb', "print('not-an-api')")
        code,r=self.run_case('normal')
        self.assertEqual(code,2)
        self.assertFalse(any(c['kind']=='flutter' for c in r['commands']))


    def test_api_stderr_banner_does_not_contaminate_successful_stdout(self):
        self.executable('adb', "if 'getprop' in sys.argv:\n    print('* daemon started successfully',file=sys.stderr)\n    print('24')")
        code,r=self.run_case('normal')
        self.assertEqual(code,0)
        self.assertTrue(any(c['kind']=='flutter' for c in r['commands']))
        api=next(c for c in r['commands'] if c['kind']=='api')
        self.assertIn('daemon started',Path(api['stderrLog']).read_text())

    def test_signal_during_log_replay_cannot_report_success(self):
        with mock.patch.dict(os.environ,self.env), mock.patch.object(tempfile,'tempdir',str(self.path)):
            runner=runner_module.Runner('suite.dart',[])
            with mock.patch.object(runner_module.shutil,'copyfileobj',side_effect=lambda *_:runner.interrupted(signal.SIGTERM,None)):
                self.assertEqual(runner.run(),128+signal.SIGTERM)
            receipt=json.loads(runner.log.with_name(runner.log.name+'.receipt.json').read_text())
            self.assertEqual(receipt['exitCode'],128+signal.SIGTERM)
            self.assertEqual(receipt['signal'],signal.SIGTERM)

    def test_receipt_is_written_after_owned_signal_handler_boundary(self):
        original={s:signal.getsignal(s) for s in runner_module.SIGNALS}
        write=Path.write_text
        def checked_write(path,*args,**kwargs):
            if str(path).endswith('.receipt.json'):
                self.assertEqual({s:signal.getsignal(s) for s in runner_module.SIGNALS},original)
            return write(path,*args,**kwargs)
        with mock.patch.dict(os.environ,self.env), mock.patch.object(tempfile,'tempdir',str(self.path)), mock.patch.object(Path,'write_text',checked_write):
            self.assertEqual(runner_module.Runner('suite.dart',[]).run(),0)


if __name__=='__main__':unittest.main()
