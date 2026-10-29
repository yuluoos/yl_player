import json
import plistlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

import network_profile
import abr_accesslog
from types import SimpleNamespace
try:
    import abr_device
except ImportError:
    abr_device = None


class DeviceCaptureTests(unittest.TestCase):
    def test_physical_preflight_binds_device_kind_and_rejects_public_listener(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            args = SimpleNamespace(directory=root/'capture', products=root/'missing', device=None,
                physical_device='00008140-000C49CC3493001C', owned_host='8.8.8.8')
            result = abr_accesslog.run(args)
            self.assertEqual(result.get('deviceKind'), 'physical')
            self.assertEqual(result['errors'], ['ValueError'])
            self.assertFalse(result['passed'])

    def test_listener_requires_explicit_literal_private_address(self):
        validate = getattr(network_profile, 'owned_bind_host', None)
        self.assertIsNotNone(validate)
        self.assertEqual(validate(None), '127.0.0.1')
        for value in ['10.1.2.3', '172.16.1.2', '192.168.50.196']:
            self.assertEqual(validate(value), value)
        for value in ['0.0.0.0', '127.0.0.1', '8.8.8.8', '169.254.1.1', '172.32.1.1',
                      '192.168.001.1', 'localhost', '::1', '', True]:
            with self.subTest(value=value), self.assertRaises(ValueError): validate(value)

    def test_device_cleanup_requires_matching_pid_and_executable(self):
        self.assertIsNotNone(abr_device)
        proof = dict(pid=123, executable='/private/var/containers/Bundle/Application/owned/Runner.app/Runner', token='a'*32, deviceKind='physical')
        process = dict(processIdentifier=123, executable='file:///private/var/containers/Bundle/Application/owned/Runner.app/Runner')
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp); (out/'process.json').write_text(json.dumps(proof))
            with patch('abr_device.processes', side_effect=[[process], []]), patch('abr_device.invoke') as invoke:
                self.assertTrue(abr_device.cleanup('device', out, 'a'*32, 'Runner'))
                self.assertEqual(invoke.call_args.args[0][-2:], ['--pid', '123'])
            for entries in [[], [dict(process, executable='file:///other/Runner.app/Runner')]]:
                with patch('abr_device.processes', return_value=entries), patch('abr_device.invoke') as invoke:
                    self.assertEqual(abr_device.cleanup('device', out, 'a'*32, 'Runner'), not entries)
                    invoke.assert_not_called()
            with self.assertRaises(ValueError): abr_device.cleanup('device', out, 'b'*32, 'Runner')

    def test_export_copies_only_one_complete_owned_file_set(self):
        self.assertIsNotNone(abr_device)
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp); export=out/'device-export'; export.mkdir()
            (export/'rows.jsonl').write_text('{}\n'); (export/'frame-samples.jsonl').write_text('{}\n')
            (export/'process.json').write_text('{}')
            (export/'proxy-requests.jsonl').write_text('{"version":1}\n')
            with patch('abr_device.invoke'):
                abr_device.collect('device', 'bundle', out, 'a'*32)
            self.assertEqual((out/'rows.jsonl').read_text(), '{}\n')
            self.assertEqual((out/'proxy-requests.jsonl').read_text(), '{"version":1}\n')
            duplicate=export/'duplicate'; duplicate.mkdir();(duplicate/'rows.jsonl').write_text('{}')
            with patch('abr_device.invoke'), self.assertRaises(ValueError):
                abr_device.collect('device', 'bundle', out, 'a'*32)

    def test_cleanup_rejects_nonobject_proof_and_process_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            for proof in [None, [], 1, 'invalid']:
                (out/'process.json').write_text(json.dumps(proof))
                with self.subTest(proof=proof), self.assertRaises(ValueError):
                    abr_device.cleanup('device', out, 'a'*32, 'Runner')
            (out/'process.json').write_text(json.dumps(dict(pid=123, token='a'*32,
                deviceKind='physical', executable='/owned/Runner.app/Runner')))
            for entries in [None, {}, [None], [dict(processIdentifier=123, executable=1)]]:
                with self.subTest(entries=entries), patch('abr_device.processes', return_value=entries), \
                        patch('abr_device.invoke') as invoke, self.assertRaises(ValueError):
                    abr_device.cleanup('device', out, 'a'*32, 'Runner')
                invoke.assert_not_called()

    def test_nonobject_device_rows_keep_failed_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            products = root / 'products'
            app = products / 'Runner.app'
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleExecutable': 'Runner', 'CFBundleIdentifier': 'owned.bundle'}))
            (app / 'Runner').write_bytes(b'owned mock executable')
            (products / 'probe.xctestrun').write_bytes(plistlib.dumps({
                'RunnerTests': {'TestHostPath': '__TESTROOT__/Runner.app/Runner'}}))
            args = SimpleNamespace(directory=root / 'capture', products=products, device=None,
                physical_device='00008140-000C49CC3493001C', owned_host='192.168.50.196',
                profiles=Path('unused'), profile='owned')
            server = Mock(server_port=1234)
            process = Mock()
            process.poll.return_value = 0
            with patch('abr_accesslog.create', return_value={}), \
                    patch('abr_accesslog.load_profiles', return_value={'owned': SimpleNamespace(sha256='mock')}), \
                    patch('abr_accesslog.make_server', return_value=server), \
                    patch('abr_accesslog.subprocess.Popen', return_value=process), \
                    patch('abr_accesslog.wait_for_native', return_value=0), \
                    patch('abr_accesslog.abr_device.collect'), \
                    patch('abr_accesslog.abr_device.cleanup', return_value=True), \
                    patch('abr_accesslog.read_rows', return_value=[None, None]):
                receipt = abr_accesslog.run(args)
            self.assertFalse(receipt['passed'])
            self.assertEqual(receipt['errors'], ['ValueError', 'connection evidence incomplete'])
            self.assertEqual(receipt['exitCode'], 0)
            self.assertEqual(json.loads((args.directory/'receipt.json').read_text()), receipt)

if __name__ == '__main__': unittest.main()
