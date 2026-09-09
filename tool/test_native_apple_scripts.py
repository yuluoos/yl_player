import os
import pathlib
import re
import select
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
WRAPPER = REPO_ROOT / "tool" / "run_with_display_awake.py"
BINDING = re.compile(
    r"Temporary display assertion (?P<awake>\d+) bound to owned command (?P<command>\d+)"
)
REQUIRES_CAFFEINATE = unittest.skipUnless(
    pathlib.Path("/usr/bin/caffeinate").is_file(), "requires macOS caffeinate"
)


class DisplayAwakeRunnerTest(unittest.TestCase):
    def _run_wrapper(self, *command, timeout=10):
        return subprocess.run(
            [sys.executable, str(WRAPPER), *command],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
        )

    def _start_wrapper(self, *command):
        wrapper = subprocess.Popen(
            [sys.executable, str(WRAPPER), *command],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        self.assertIsNotNone(wrapper.stdout)
        readable, _, _ = select.select([wrapper.stdout], [], [], 5)
        self.assertTrue(readable, "wrapper did not publish its owned process IDs")
        line = wrapper.stdout.readline()
        match = BINDING.fullmatch(line.strip())
        self.assertIsNotNone(match, line)
        return wrapper, int(match.group("command")), int(match.group("awake")), line

    def _pid_exists(self, pid):
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False

    def _assert_pid_gone(self, pid, timeout=5):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if not self._pid_exists(pid):
                return
            time.sleep(0.02)
        self.fail(f"owned process {pid} remained alive")

    def _kill_if_alive(self, pid):
        if not pid:
            return
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            return

    def _binding_pids(self, output):
        match = BINDING.search(output)
        self.assertIsNotNone(match, output)
        return int(match.group("command")), int(match.group("awake"))

    def _read_available(self, stream):
        output = ""
        while select.select([stream], [], [], 0.05)[0]:
            line = stream.readline()
            if not line:
                break
            output += line
        return output

    @REQUIRES_CAFFEINATE
    def test_real_success_preserves_zero_and_releases_actual_assertion(self):
        result = self._run_wrapper(sys.executable, "-c", "import time; time.sleep(.1)")

        self.assertEqual(result.returncode, 0, result.stdout)
        command_pid, awake_pid = self._binding_pids(result.stdout)
        self.assertIn("Temporary display assertion released", result.stdout)
        self._assert_pid_gone(command_pid)
        self._assert_pid_gone(awake_pid)

    @REQUIRES_CAFFEINATE
    def test_real_nonzero_status_is_preserved_and_actual_assertion_is_released(self):
        result = self._run_wrapper(sys.executable, "-c", "raise SystemExit(7)")

        self.assertEqual(result.returncode, 7, result.stdout)
        command_pid, awake_pid = self._binding_pids(result.stdout)
        self.assertIn("Temporary display assertion released", result.stdout)
        self._assert_pid_gone(command_pid)
        self._assert_pid_gone(awake_pid)

    @REQUIRES_CAFFEINATE
    def test_real_child_signal_is_preserved_as_a_signal(self):
        result = self._run_wrapper(
            sys.executable,
            "-c",
            "import os,signal,time; time.sleep(.1); os.kill(os.getpid(), signal.SIGTERM)",
        )

        self.assertEqual(result.returncode, -signal.SIGTERM, result.stdout)
        command_pid, awake_pid = self._binding_pids(result.stdout)
        self.assertIn("Temporary display assertion released", result.stdout)
        self._assert_pid_gone(command_pid)
        self._assert_pid_gone(awake_pid)

    @REQUIRES_CAFFEINATE
    def test_wrapper_sigterm_escalates_and_reaps_its_owned_process_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            pids_file = root / "pids"
            command_marker = root / "command-term"
            descendant_marker = root / "descendant-term"
            descendant_ready = root / "descendant-ready"
            descendant = textwrap.dedent(
                f"""
                import pathlib, signal, time
                marker = pathlib.Path({str(descendant_marker)!r})
                signal.signal(signal.SIGTERM, lambda *_: marker.write_text('term'))
                pathlib.Path({str(descendant_ready)!r}).write_text('ready')
                while True:
                    time.sleep(1)
                """
            )
            command = textwrap.dedent(
                f"""
                import os, pathlib, signal, subprocess, sys, time
                marker = pathlib.Path({str(command_marker)!r})
                signal.signal(signal.SIGTERM, lambda *_: marker.write_text('term'))
                descendant = subprocess.Popen([sys.executable, '-c', {descendant!r}])
                deadline = time.monotonic() + 2
                while not pathlib.Path({str(descendant_ready)!r}).exists() and time.monotonic() < deadline:
                    time.sleep(.01)
                pathlib.Path({str(pids_file)!r}).write_text(f'{{os.getpid()}} {{descendant.pid}}')
                while True:
                    time.sleep(1)
                """
            )
            wrapper = None
            command_pid = awake_pid = descendant_pid = None
            try:
                wrapper, command_pid, awake_pid, output = self._start_wrapper(
                    sys.executable, "-c", command
                )
                deadline = time.monotonic() + 5
                while not pids_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(pids_file.exists(), "command did not publish descendant PID")
                recorded_command, descendant_pid = map(int, pids_file.read_text().split())
                self.assertEqual(recorded_command, command_pid)
                assertion_command = subprocess.check_output(
                    ["ps", "-o", "command=", "-p", str(awake_pid)], text=True
                ).strip()
                self.assertEqual(
                    assertion_command,
                    f"/usr/bin/caffeinate -d -i -u -t 240 -w {command_pid}",
                )

                started = time.monotonic()
                os.kill(wrapper.pid, signal.SIGTERM)
                returncode = wrapper.wait(timeout=7)
                elapsed = time.monotonic() - started
                output += self._read_available(wrapper.stdout)

                self.assertEqual(returncode, -signal.SIGTERM, output)
                self.assertLess(elapsed, 6, "owned-process cleanup exceeded its bound")
                self.assertTrue(command_marker.exists(), "SIGTERM was not forwarded to command")
                self.assertTrue(
                    descendant_marker.exists(), "SIGTERM was not forwarded to descendant"
                )
                self.assertIn("Temporary display assertion released", output)
                self._assert_pid_gone(command_pid)
                self._assert_pid_gone(descendant_pid)
                self._assert_pid_gone(awake_pid)
            finally:
                if wrapper is not None and wrapper.poll() is None:
                    wrapper.kill()
                    wrapper.wait()
                self._kill_if_alive(descendant_pid)
                self._kill_if_alive(command_pid)
                self._kill_if_alive(awake_pid)
                if wrapper is not None and wrapper.stdout is not None:
                    wrapper.stdout.close()

    @REQUIRES_CAFFEINATE
    def test_supported_wrapper_interrupts_reap_only_the_owned_command_and_assertion(self):
        for interrupt in (signal.SIGINT, signal.SIGHUP):
            with self.subTest(interrupt=interrupt):
                wrapper = None
                command_pid = awake_pid = None
                try:
                    wrapper, command_pid, awake_pid, output = self._start_wrapper(
                        sys.executable, "-c", "import time; time.sleep(60)"
                    )
                    os.kill(wrapper.pid, interrupt)
                    returncode = wrapper.wait(timeout=5)
                    output += self._read_available(wrapper.stdout)

                    self.assertEqual(returncode, -interrupt, output)
                    self.assertIn("Temporary display assertion released", output)
                    self._assert_pid_gone(command_pid)
                    self._assert_pid_gone(awake_pid)
                finally:
                    if wrapper is not None and wrapper.poll() is None:
                        wrapper.kill()
                        wrapper.wait()
                    self._kill_if_alive(command_pid)
                    self._kill_if_alive(awake_pid)
                    if wrapper is not None and wrapper.stdout is not None:
                        wrapper.stdout.close()

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
