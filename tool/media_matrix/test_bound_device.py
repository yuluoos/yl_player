"""Physical transport must reject foreign paths and stale/failed copies."""
import json
import tempfile
import subprocess
import sys
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from bound_device import DeviceTransport

RUN='12345678-1234-1234-1234-123456789abc'

class DeviceTransportTest(unittest.TestCase):
    def setUp(self):
        self.directory=tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root=Path(self.directory.name)
        self.transport=DeviceTransport('owned-device','dev.ylplayer.example',RUN,self.root)

    def test_copy_is_scoped_to_this_app_and_uuid_not_device_supplied_host_path(self):
        command=self.transport.copy_command('status.json',self.root/'status-copy.json')
        self.assertIn('appDataContainer',command)
        self.assertIn('dev.ylplayer.example',command)
        self.assertIn('tmp/p03-public-'+RUN+'/status.json',command)
        for name in ['../status.json','/private/file','other.json','rows.json/../status.json']:
            with self.assertRaises(ValueError): self.transport.copy_command(name,self.root/'out')

    def test_failed_copy_never_reuses_previous_success(self):
        with patch('bound_device.subprocess.run') as run:
            def copy(command,**kwargs):
                target=Path(command[command.index('--destination')+1])
                target.write_text(json.dumps({'runId':RUN,'passed':True}))
                class Result: returncode=0
                return Result()
            run.side_effect=copy
            self.assertTrue(self.transport.read_json('status.json')['passed'])
            class Failed: returncode=1
            run.side_effect=None;run.return_value=Failed()
            self.assertIsNone(self.transport.read_json('status.json'))

    def test_wrong_run_malformed_and_oversized_status_are_rejected(self):
        for raw in [json.dumps({'runId':'another','passed':True}),'[]','{broken','x'*65537]:
            with self.subTest(raw=raw[:50]),patch('bound_device.subprocess.run') as run:
                def copy(command,**kwargs):
                    Path(command[command.index('--destination')+1]).write_text(raw)
                    class Result: returncode=0
                    return Result()
                run.side_effect=copy
                with self.assertRaises(ValueError):self.transport.read_json('status.json')

    def test_launch_preserves_prebuilt_debug_app_and_uses_no_rebuild(self):
        command=self.transport.launch_command('/opt/flutter/bin/flutter',self.root/'owned.app')
        self.assertIn('--use-application-binary='+str(self.root/'owned.app'),command)
        self.assertIn('--debug',command)
        self.assertIn('--no-hot',command)
        self.assertNotIn('--release',command)
        self.assertNotIn('--no-resident',command)
        self.assertIn('owned-device',command)

    def test_stop_requires_owned_app_id_and_successful_machine_reply(self):
        script = """
import json, sys
print(json.dumps([{'event':'app.start','params':{'appId':'owned-app','deviceId':'owned-device'}}]),flush=True)
request=json.loads(sys.stdin.readline())[0]
valid=request['method']=='app.stop' and request['params']['appId']=='owned-app'
print(json.dumps([{'id':request['id'],'result':valid}]),flush=True)
"""
        path=self.root/'flutter.log'
        with path.open('wb') as log:
            process=subprocess.Popen([sys.executable,'-c',script],stdin=subprocess.PIPE,stdout=log)
            try:
                deadline=time.monotonic()+5
                while not self.transport.events(path) and time.monotonic()<deadline:time.sleep(.01)
                self.assertTrue(self.transport.stop(process,path))
                self.assertEqual(0,process.returncode)
            finally:
                if process.poll() is None:process.kill();process.wait()
                process.stdin.close()

    def test_exited_launcher_without_stop_receipt_is_not_cleaned_up(self):
        path=self.root/'exited.log';path.write_text('[]\n')
        process=subprocess.Popen([sys.executable,'-c','pass'],stdin=subprocess.PIPE)
        process.wait();process.stdin.close()
        self.assertFalse(self.transport.stop(process,path))

    def test_prepare_rejects_simulator_or_foreign_device_before_install(self):
        for reality,udid in [('simulated','owned-device'),('physical','different-device'),(None,'owned-device')]:
            with self.subTest(reality=reality,udid=udid),patch('bound_device.subprocess.run') as run:
                def response(command,**kwargs):
                    if 'details' not in command:raise AssertionError('must reject target before installation')
                    Path(command[command.index('--json-output')+1]).write_text(json.dumps({
                        'result':{'hardwareProperties':{'platform':'iOS','reality':reality,'udid':udid}}}))
                    class Result:returncode=0
                    return Result()
                run.side_effect=response
                with self.assertRaises(ValueError):self.transport.prepare(self.root/'app','encoded-plan')

    def test_early_native_result_waits_for_owned_flutter_start_before_stopping(self):
        path=self.root/'starting.log'
        events=[{'event':'app.start','params':{'appId':'owned','deviceId':'owned-device'}}]
        path.write_text(json.dumps(events)+'\n')
        self.assertFalse(self.transport.has_started(path))
        with path.open('a') as log:log.write(json.dumps([{'event':'app.started','params':{'appId':'foreign'}}])+'\n')
        self.assertFalse(self.transport.has_started(path))
        with path.open('a') as log:log.write(json.dumps([{'event':'app.started','params':{'appId':'owned'}}])+'\n')
        self.assertTrue(self.transport.has_started(path))

    def test_invalid_run_identity_is_rejected_before_device_commands(self):
        for run in ['../somewhere','', 'not-a-uuid']:
            with self.assertRaises(ValueError):DeviceTransport('device','bundle',run,self.root)

if __name__=='__main__':unittest.main()
