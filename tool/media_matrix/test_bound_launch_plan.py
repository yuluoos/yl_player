"""Exercise the opt-in native one-shot input with real files and Swift code."""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Diagnostics/YlBoundLaunchPlan.swift'

@unittest.skipUnless(os.uname().sysname=='Darwin','Apple native launch input')
class LaunchPlanTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build=tempfile.TemporaryDirectory();cls.addClassCleanup(cls.build.cleanup)
        folder=Path(cls.build.name)
        (folder/'main.swift').write_text('''import Foundation
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
do {
 let value = try YlBoundLaunchPlan.consume(environment: [:], directory: folder)
 print(value ?? "NO_PLAN")
} catch { print("INVALID_PLAN"); exit(2) }
''')
        cls.executable=folder/'test'
        subprocess.run(['xcrun','swiftc','-D','DEBUG','-D','YL_BOUND_AV',str(SOURCE),str(folder/'main.swift'),'-o',str(cls.executable)],check=True,capture_output=True)
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.folder=Path(self.temp.name);self.file=self.folder/'p03-bound-plan.txt'
    def invoke(self):
        return subprocess.run([str(self.executable),str(self.folder)],capture_output=True,text=True)
    def test_plan_is_consumed_once_and_does_not_replay_after_relaunch(self):
        self.file.write_text('owned-base64-plan')
        first=self.invoke();self.assertEqual(0,first.returncode);self.assertEqual('owned-base64-plan',first.stdout.strip())
        self.assertFalse(self.file.exists());self.assertEqual('NO_PLAN',self.invoke().stdout.strip())
    def test_missing_plan_does_not_enable_observer(self):
        self.assertEqual('NO_PLAN',self.invoke().stdout.strip())
    def test_oversized_and_non_utf8_input_cannot_enable_observer(self):
        for data in [b'x'*(1024*1024+1),b'\xff',b'']:
            self.file.write_bytes(data)
            self.assertEqual(2,self.invoke().returncode)
    def test_link_cannot_read_or_remove_other_file(self):
        other=self.folder/'unrelated';other.write_text('private')
        self.file.symlink_to(other)
        self.assertEqual(2,self.invoke().returncode)
        self.assertEqual('private',other.read_text())

if __name__=='__main__':unittest.main()
