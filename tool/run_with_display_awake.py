#!/usr/bin/env python3

import os
import signal
import subprocess
import sys
import time


CLEANUP_TIMEOUT_SECONDS = 2.0
WAIT_INTERVAL_SECONDS = 0.05
SUPPORTED_SIGNALS = tuple(
    getattr(signal, name)
    for name in ("SIGHUP", "SIGINT", "SIGTERM")
    if hasattr(signal, name)
)


def _process_group_exists(process_group):
    try:
        os.killpg(process_group, 0)
        return True
    except (ProcessLookupError, PermissionError):
        return False


def _signal_command_tree(process, signum):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass
    except PermissionError:
        if process.poll() is None:
            process.send_signal(signum)


def _stop_command_tree(process, signum):
    process_group = process.pid
    _signal_command_tree(process, signum)
    deadline = time.monotonic() + CLEANUP_TIMEOUT_SECONDS
    while _process_group_exists(process_group) and time.monotonic() < deadline:
        if process.poll() is None:
            try:
                process.wait(timeout=WAIT_INTERVAL_SECONDS)
            except subprocess.TimeoutExpired:
                pass
        else:
            time.sleep(WAIT_INTERVAL_SECONDS)
    if _process_group_exists(process_group):
        _signal_command_tree(process, signal.SIGKILL)
    if process.poll() is None:
        try:
            process.wait(timeout=CLEANUP_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            print(
                f"Owned command {process.pid} did not exit after SIGKILL",
                file=sys.stderr,
                flush=True,
            )


def _stop_process(process):
    if process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=CLEANUP_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            process.wait(timeout=CLEANUP_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            print(
                f"Display assertion {process.pid} did not exit after SIGKILL",
                file=sys.stderr,
                flush=True,
            )


def run(command):
    requested_signal = [None]

    def request_termination(signum, _frame):
        if requested_signal[0] is None:
            requested_signal[0] = signum

    previous_handlers = {
        signum: signal.signal(signum, request_termination)
        for signum in SUPPORTED_SIGNALS
    }
    process = None
    awake = None
    status = None
    try:
        process = subprocess.Popen(command, start_new_session=True)
        if requested_signal[0] is not None:
            _stop_command_tree(process, requested_signal[0])
            status = -requested_signal[0]
        else:
            try:
                awake = subprocess.Popen(
                    [
                        "/usr/bin/caffeinate",
                        "-d",
                        "-i",
                        "-u",
                        "-t",
                        "240",
                        "-w",
                        str(process.pid),
                    ]
                )
            except BaseException:
                _stop_command_tree(process, signal.SIGTERM)
                raise

            print(
                f"Temporary display assertion {awake.pid} bound to owned command "
                f"{process.pid}",
                flush=True,
            )
            while process.poll() is None and requested_signal[0] is None:
                try:
                    process.wait(timeout=WAIT_INTERVAL_SECONDS)
                except subprocess.TimeoutExpired:
                    pass
            if requested_signal[0] is not None:
                _stop_command_tree(process, requested_signal[0])
                status = -requested_signal[0]
            else:
                status = process.wait()
                if status < 0:
                    _stop_command_tree(process, signal.SIGTERM)
    except BaseException:
        if process is not None and process.poll() is None:
            _stop_command_tree(process, signal.SIGTERM)
        raise
    finally:
        if awake is not None:
            _stop_process(awake)
            print("Temporary display assertion released", flush=True)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
    if requested_signal[0] is not None:
        return -requested_signal[0]
    assert status is not None
    return status


def main(arguments):
    if not arguments:
        print("usage: run_with_display_awake.py command [argument ...]", file=sys.stderr)
        return 64
    return run(arguments)


def _exit_with_status(status):
    if status >= 0:
        raise SystemExit(status)
    signum = -status
    signal.signal(signum, signal.SIG_DFL)
    os.kill(os.getpid(), signum)
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    _exit_with_status(main(sys.argv[1:]))
