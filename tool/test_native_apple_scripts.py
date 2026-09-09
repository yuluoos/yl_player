import importlib.util
import pathlib
import unittest
from unittest import mock


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]


class DisplayAwakeRunnerTest(unittest.TestCase):
    def _load_runner(self):
        path = REPO_ROOT / "tool" / "run_with_display_awake.py"
        spec = importlib.util.spec_from_file_location("run_with_display_awake", path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    @mock.patch("subprocess.Popen")
    def test_binds_and_releases_display_assertion(self, popen):
        command = mock.Mock(pid=1234)
        command.wait.return_value = 7
        awake = mock.Mock(pid=5678)
        awake.poll.return_value = None
        popen.side_effect = [command, awake]

        runner = self._load_runner()
        status = runner.run(["xcodebuild", "test"])

        self.assertEqual(status, 7)
        self.assertEqual(
            popen.call_args_list,
            [
                mock.call(["xcodebuild", "test"]),
                mock.call(
                    [
                        "/usr/bin/caffeinate",
                        "-d",
                        "-i",
                        "-u",
                        "-t",
                        "240",
                        "-w",
                        "1234",
                    ]
                ),
            ],
        )
        awake.terminate.assert_called_once_with()
        awake.wait.assert_called_once_with()

    @mock.patch("subprocess.Popen")
    def test_stops_command_when_display_assertion_cannot_start(self, popen):
        command = mock.Mock(pid=1234)
        popen.side_effect = [command, OSError("caffeinate unavailable")]

        runner = self._load_runner()
        with self.assertRaisesRegex(OSError, "caffeinate unavailable"):
            runner.run(["xcodebuild", "test"])

        command.terminate.assert_called_once_with()
        command.wait.assert_called_once_with()

    def test_macos_native_gate_uses_bounded_runner(self):
        script = (REPO_ROOT / "tool" / "check_native_macos.sh").read_text()
        self.assertIn(
            'python3 -B "$repo_root/tool/run_with_display_awake.py" xcodebuild test',
            script,
        )
        self.assertIn(
            'python3 -B "$repo_root/tool/run_with_display_awake.py" '
            'flutter test "$test_file" -d macos',
            script,
        )


if __name__ == "__main__":
    unittest.main()
