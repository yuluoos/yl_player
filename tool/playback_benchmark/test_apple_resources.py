import ctypes
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


@unittest.skipUnless(sys.platform=='darwin','Apple sampler requires macOS')
class AppleResourcesTests(unittest.TestCase):
    def test_actual_self_process_cpu_and_memory_counters(self):
        with tempfile.TemporaryDirectory(prefix='yl-resource-self-') as directory:
            library=Path(directory)/'resources.dylib'
            subprocess.run(['sh',str(Path(__file__).with_name('build_apple_resources.sh')),str(library)],check=True)
            native=ctypes.CDLL(str(library)); read=native.yl_resource_snapshot;read.restype=ctypes.c_char_p
            before=json.loads(read());self.assertEqual(before['status'],'ok')
            allocation=bytearray(32*1024*1024)
            for i in range(0,len(allocation),4096): allocation[i]=123
            deadline=time.monotonic()+0.1
            while time.monotonic()<deadline: pass
            after=json.loads(read());self.assertEqual(after['status'],'ok')
            self.assertGreater(after['monotonicUs'],before['monotonicUs'])
            self.assertGreater(after['cpuUs'],before['cpuUs'])
            self.assertGreater(after['rssBytes'],before['rssBytes']+16*1024*1024)
            self.assertGreater(after['footprintBytes'],before['footprintBytes']+16*1024*1024)
            self.assertIn(after['thermal'],['nominal','fair','serious','critical','unknown'])
            self.assertIn(after['power'],['ac','battery','unknown'])
            self.assertEqual(allocation[0],123)

if __name__=='__main__':unittest.main()
