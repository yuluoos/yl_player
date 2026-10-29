#!/usr/bin/env python3
"""Bounded POSIX host orchestration; never owns a device or global adb daemon."""
from contextlib import ExitStack
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

COMPONENT = 'dev.ylplayer.yl_player_example/dev.ylplayer.yl_player_example.MainActivity'
BACKGROUND = b'YL_ANDROID_LIFECYCLE_BACKGROUND_READY'
FOREGROUND = b'YL_ANDROID_LIFECYCLE_FOREGROUND_READY'
SIGNALS = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)


class Failed(Exception):
    def __init__(self, code):
        self.code = code


def limit(name, maximum):
    value = float(os.environ.get(name, maximum))
    if not math.isfinite(value) or not 0 < value <= maximum:
        raise ValueError(name)
    return value


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # Failure to inspect is not proof of release.
        return True


def exit_code(code):
    return code if code >= 0 else 128 - code


class Runner:
    def __init__(self, suite, extra):
        self.serial = os.environ['YL_ANDROID_DEVICE_ID']
        if not self.serial:
            raise ValueError('device')
        self.run_seconds = limit('YL_ANDROID_RUN_TIMEOUT_SECONDS', 600)
        self.adb_seconds = limit('YL_ANDROID_ADB_TIMEOUT_SECONDS', 15)
        self.cleanup_seconds = limit('YL_ANDROID_CLEANUP_TIMEOUT_SECONDS', 30)
        self.adb = os.environ.get('YL_ADB', 'adb')
        self.flutter = os.environ.get('YL_FLUTTER', 'flutter')
        self.suite, self.extra = suite, extra
        fd, name = tempfile.mkstemp(prefix='yl-android-test.')
        os.close(fd)
        self.log = Path(name)
        self.commands = []
        self.processes = []
        self.requested_signal = None
        self.background = self.foreground = False
        self.offset = 0
        self.tail = b''
        self.cleanup_errors = []

    def interrupted(self, signum, _frame):
        if self.requested_signal is None:
            self.requested_signal = signum

    def spawn(self, kind, args, output, stderr_output=None):
        record = dict(kind=kind, command=args, timedOut=False, exitCode=None)
        self.commands.append(record)
        try:
            with ExitStack() as stack:
                stream = stack.enter_context(output.open('wb'))
                errors = subprocess.STDOUT
                if stderr_output is not None:
                    errors = stack.enter_context(stderr_output.open('wb'))
                    record['stderrLog'] = str(stderr_output)
                process = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                                           stdout=stream, stderr=errors,
                                           start_new_session=True)
        except OSError as error:
            record['errorType'] = type(error).__name__
            raise Failed(127) from error
        record['pid'] = process.pid
        self.processes.append((process, record))
        return process, record

    def check_deadline(self, deadline, record, cleanup=False):
        if not cleanup and self.requested_signal is not None:
            raise Failed(128 + self.requested_signal)
        if time.monotonic() >= deadline:
            record['timedOut'] = True
            raise Failed(124)

    def adb_command(self, kind, args, deadline, output=None, cleanup=False):
        deadline = min(deadline, time.monotonic() + self.adb_seconds)
        self.check_deadline(deadline, {}, cleanup)
        output = output or self.log.with_name(self.log.name + '.' + kind)
        errors = output.with_name(output.name + '.stderr') if kind == 'api' else None
        process, record = self.spawn(kind, [self.adb, '-s', self.serial, *args], output, errors)
        while process.poll() is None:
            self.check_deadline(deadline, record, cleanup)
            time.sleep(.02)
        record['exitCode'] = exit_code(process.returncode)
        if process.returncode:
            raise Failed(record['exitCode'])
        if not self.retired(process, record):
            # A completed adb client must not leave same-session helpers running.
            raise Failed(70)
        return output

    def lifecycle(self, deadline):
        # Incremental binary reads preserve markers split between chunks.
        with self.log.open('rb') as stream:
            stream.seek(self.offset)
            data = stream.read(65536)
            self.offset += len(data)
        data = self.tail + data
        self.tail = data[-max(len(BACKGROUND), len(FOREGROUND)):]
        if not self.background and BACKGROUND in data:
            self.background = True  # A failed adb reply may still have sent HOME.
            self.adb_command('background', ['shell', 'input', 'keyevent', 'KEYCODE_HOME'], deadline)
        if self.background and not self.foreground and FOREGROUND in data:
            self.adb_command('foreground', ['shell', 'am', 'start', '-n', COMPONENT], deadline)
            self.foreground = True

    def retired(self, process, record):
        if record.get('groupRetired', False):
            return True
        process.poll()
        if not group_exists(process.pid):
            record['groupRetired'] = True
            return True
        return False

    def stop_groups(self, deadline):
        def active():
            return [(p, r) for p, r in self.processes if not self.retired(p, r)]

        def send(signum):
            for process, record in active():
                try:
                    os.killpg(process.pid, signum)
                except ProcessLookupError:
                    record['groupRetired'] = True
                except PermissionError:
                    self.cleanup_errors.append(dict(pgid=process.pid, signal=signum, error='PermissionError'))

        send(signal.SIGTERM)
        grace = min(deadline, time.monotonic() + .25)
        while active() and time.monotonic() < grace:
            time.sleep(.02)
        if active():
            send(signal.SIGKILL)
        while active() and time.monotonic() < deadline:
            time.sleep(.02)
        return not active()

    def run(self):
        started = time.monotonic()
        deadline = started + self.run_seconds
        handlers = {s: signal.signal(s, self.interrupted) for s in SIGNALS}
        primary = 70
        error_type = None
        restore_ok = True
        try:
            api_file = self.adb_command('api', ['shell', 'getprop', 'ro.build.version.sdk'], deadline)
            api = api_file.read_text().strip()
            if not api.isascii() or not api.isdigit() or not 24 <= int(api) <= 999:
                raise Failed(2)
            self.adb_command('previous-logcat', ['logcat', '-d'], deadline)
            self.adb_command('clear-logcat', ['logcat', '-c'], deadline)
            process, record = self.spawn('flutter', [self.flutter, 'test', self.suite, *self.extra,
                '-d', self.serial, '--timeout', '5m', '--dart-define=YL_ANDROID_API=' + api], self.log)
            while process.poll() is None:
                self.check_deadline(deadline, record)
                self.lifecycle(deadline)
                time.sleep(.02)
            primary = record['exitCode'] = exit_code(process.returncode)
        except Failed as error:
            primary = error.code
        except Exception as error:
            error_type = type(error).__name__
        finally:
            cleanup_deadline = time.monotonic() + self.cleanup_seconds
            self.stop_groups(cleanup_deadline)
            # Reserve time to stop diagnostic processes too; never reset the budget.
            diagnostic_deadline = cleanup_deadline - min(.3, self.cleanup_seconds / 3)
            if self.background and not self.foreground:
                try:
                    self.adb_command('restore', ['shell', 'am', 'start', '-n', COMPONENT],
                                     diagnostic_deadline, cleanup=True)
                    self.foreground = True
                except Failed:
                    restore_ok = False
            if primary != 0:
                try:
                    self.adb_command('failure-logcat', ['logcat', '-d'], diagnostic_deadline, cleanup=True)
                except Failed:
                    pass  # Diagnostic failure cannot replace the test failure.
            complete = self.stop_groups(cleanup_deadline)
            for process, record in self.processes:
                if process.poll() is not None and record['exitCode'] is None:
                    record['exitCode'] = exit_code(process.returncode)
            status = primary or (70 if not complete or not restore_ok else 0)
            try:
                with self.log.open('rb') as stream:
                    shutil.copyfileobj(stream, sys.stdout.buffer)
                sys.stdout.flush()
            except OSError:
                status = status or 70
            # End our signal ownership before freezing the receipt. Signals
            # received during log replay are included; subsequent signals use
            # the caller's prior handlers and cannot mutate this saved outcome.
            for signum, handler in handlers.items():
                signal.signal(signum, handler)
            if self.requested_signal is not None:
                status = 128 + self.requested_signal
            receipt = dict(schemaVersion=1, serial=self.serial, suite=self.suite,
                limits=dict(runSeconds=self.run_seconds, adbSeconds=self.adb_seconds,
                            cleanupSeconds=self.cleanup_seconds),
                elapsedSeconds=time.monotonic()-started, primaryExitCode=primary, exitCode=status,
                signal=self.requested_signal, errorType=error_type, commands=self.commands,
                cleanup=dict(complete=complete, foregroundRestored=restore_ok,
                             errors=self.cleanup_errors,
                             groups=[dict(pgid=p.pid, leaderReturnCode=p.returncode,
                                          remaining=not r.get('groupRetired', False)) for p, r in self.processes]))
            receipt_path = self.log.with_name(self.log.name + '.receipt.json')
            try:
                receipt_path.write_text(json.dumps(receipt, indent=2) + '\n')
            except OSError:
                status = status or 70
            print('Android test log: ' + str(self.log), file=sys.stderr)
            print('Android test receipt: ' + str(receipt_path), file=sys.stderr)
        return status


def main():
    try:
        if len(sys.argv) < 2:
            raise ValueError('suite')
        return Runner(sys.argv[1], sys.argv[2:]).run()
    except (KeyError, ValueError) as error:
        print('Android runner configuration error: ' + str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
