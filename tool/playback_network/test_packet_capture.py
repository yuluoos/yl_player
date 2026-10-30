import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock,patch

from packet_capture import PacketCapture,worker_source


class BoundedCaptureTests(unittest.TestCase):
    def run_worker(self, stop, blocked_interrupt=False):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            child=root/'owned-child.py'
            child.write_text('''import signal,sys,time
signal.signal(signal.SIGINT,lambda *_:sys.exit(0))
print('listening on owned-test',file=sys.stderr,flush=True)
while True: time.sleep(.1)
''')
            worker=root/'worker.py'
            worker.write_text(worker_source([sys.executable, str(child)], root, 1))
            command=[sys.executable, '-I', str(worker)]
            if blocked_interrupt:
                command=[sys.executable, '-I', '-c',
                         'import os,signal,sys;signal.pthread_sigmask(signal.SIG_BLOCK,[signal.SIGINT]);os.execv(sys.executable,[sys.executable,"-I",sys.argv[1]])',str(worker)]
            process=subprocess.Popen(command)
            try:
                deadline=time.monotonic()+3
                while not (root/'ready').exists() and time.monotonic()<deadline:time.sleep(.02)
                self.assertTrue((root/'ready').exists())
                if stop:(root/'stop').touch()
                self.assertEqual(process.wait(timeout=8),0)
                result=json.loads((root/'done.json').read_text())
                self.assertEqual(result['exitCode'],0)
                self.assertLess(result['durationSeconds'],3)
                return result
            finally:
                if process.poll() is None:process.kill();process.wait()

    def test_explicit_stop_drains_capture(self):
        self.assertEqual(self.run_worker(True)['reason'],'stop-requested')

    def test_capture_stops_at_deadline_without_parent_signal(self):
        self.assertEqual(self.run_worker(False)['reason'],'deadline')

    def test_authorization_inherited_blocked_interrupt_is_unblocked(self):
        self.assertEqual(self.run_worker(True,blocked_interrupt=True)['reason'],'stop-requested')

    def test_kernel_file_limit_prevents_polling_overshoot(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);limit=65536
            child=root/'oversized.py'
            child.write_text('from pathlib import Path\nPath(__file__).with_name("capture.pcap").write_bytes(b"x"*131072)\n')
            worker=root/'worker.py'
            worker.write_text(worker_source([sys.executable,str(child)],root,2,max_bytes=limit))
            result=subprocess.run([sys.executable,'-I',str(worker)],timeout=4)
            self.assertEqual(result.returncode,0)
            self.assertEqual((root/'capture.pcap').stat().st_size,limit)
            metadata=json.loads((root/'done.json').read_text())
            self.assertEqual(metadata['reason'],'size-limit')
            self.assertNotEqual(metadata['exitCode'],0)

    def test_authentication_failure_is_not_a_started_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            capture=PacketCapture(Path(directory)/'capture','en0','192.168.50.196',12345)
            process=Mock();process.poll.return_value=1
            with patch('packet_capture.subprocess.Popen',return_value=process):
                with self.assertRaisesRegex(ValueError,'authorization or startup failed'):capture.start()
            result=capture.stop()
            self.assertFalse(result['complete']);self.assertFalse(result['packetCapturePerformed'])
            self.assertTrue((capture.directory/'stop').exists())

    def test_only_clean_stop_with_capture_statistics_is_complete(self):
        cases = [
            (0, 'stop-requested', '12 packets captured\n0 packets dropped by kernel\n', True),
            (0, 'stop-requested', '12 packets captured\n1 packet dropped by kernel\n', False),
            (0, 'stop-requested', 'listening on owned-test\n', False),
            (0, 'deadline', '12 packets captured\n0 packets dropped by kernel\n', False),
            (-9, 'forced-stop', '12 packets captured\n0 packets dropped by kernel\n', False),
        ]
        for code, reason, log, complete in cases:
            with self.subTest(reason=reason, log=log), tempfile.TemporaryDirectory() as directory:
                capture=PacketCapture(Path(directory)/'capture','en0','192.0.2.9',18080)
                (capture.directory/'done.json').write_text(json.dumps(dict(
                    exitCode=code, reason=reason, durationSeconds=2)))
                (capture.directory/'tcpdump.log').write_text(log)
                result=capture.stop()
                self.assertEqual(result['complete'],complete)
                self.assertTrue(result['packetCapturePerformed'])
                self.assertEqual(result['reason'],reason)
                if complete:
                    self.assertEqual(result['packetsCaptured'],12)
                    self.assertEqual(result['kernelDropped'],0)
