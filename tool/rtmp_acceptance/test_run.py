"""Focused runner ownership/receipt regressions; uses the already verified peer.

python3 -B -m unittest discover -s tool/rtmp_acceptance -p 'test_run.py' -v
No downloads or devices. Every process group created here has an owned handle.
"""
import asyncio
import contextlib
import importlib.util
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

HERE = Path(__file__).resolve().parent


def group_exists(group):
    try:
        os.killpg(group, 0)
        return True
    except ProcessLookupError:
        return False


def bounded_remove_group(group):
    # Test cleanup only receives IDs written by its own command fixture.
    with contextlib.suppress(ProcessLookupError):
        os.killpg(group, signal.SIGKILL)
    end = time.monotonic() + 3
    while group_exists(group) and time.monotonic() < end:
        time.sleep(.02)


def command_fixture(mode, record):
    record = Path(record)
    if mode in ('success', 'nonzero', 'timeout', 'cancel'):
        record.write_text(json.dumps({'group': os.getpgrp()}))
        if mode == 'success':
            return 0
        if mode == 'nonzero':
            return 7
        time.sleep(60)
        return 0
    ready = record.with_suffix('.descendant')
    child = subprocess.Popen([
        sys.executable, '-c',
        'import os,signal,time,pathlib,socket,urllib.request; '
        + ('signal.signal(signal.SIGTERM,signal.SIG_IGN); ' if mode == 'resistant' else '')
        + ('urllib.request.urlopen("http://127.0.0.1:19352/silent").close(); client=socket.create_connection(("127.0.0.1",19351)); ' if mode == 'reader' else '')
        + 'pathlib.Path(' + repr(str(ready)) + ').write_text(str(os.getpid())); time.sleep(60)',
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    end = time.monotonic() + 3
    while not ready.exists() and time.monotonic() < end:
        time.sleep(.01)
    if not ready.exists():
        raise RuntimeError('owned descendant readiness deadline')
    record.write_text(json.dumps({'group': os.getpgrp(), 'descendant': child.pid}))
    # exited: leader exits before cleanup. resistant: leader dies on TERM while
    # the same-group descendant ignores TERM, requiring group-level KILL.
    if mode == 'resistant':
        time.sleep(60)
    return 0


def runner_fixture(mode, record):
    spec = importlib.util.spec_from_file_location('rtmp_runner', HERE / 'run.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # Only the command deadline is shortened in this isolated test process.
    original = asyncio.wait_for
    async def short_deadline(awaitable, timeout):
        if timeout != 1200 or mode not in ('timeout', 'resistant'):
            return await original(awaitable, timeout)
        # The short deadline measures termination of an established fixture,
        # not Python startup/import latency under concurrent native builds.
        task = asyncio.ensure_future(awaitable)
        try:
            ready_deadline = asyncio.get_running_loop().time() + 5
            while not Path(record).exists() and not task.done():
                if asyncio.get_running_loop().time() >= ready_deadline:
                    raise RuntimeError('owned command readiness deadline')
                await asyncio.sleep(.01)
            return await original(task, .2)
        finally:
            if not task.done():
                task.cancel()
                await asyncio.gather(task, return_exceptions=True)
    asyncio.wait_for = short_deadline
    return asyncio.run(module.main([sys.executable, str(Path(__file__).resolve()), 'command', mode, record]))


class MemoryWriter:
    def __init__(self):
        self.closed = False
        self.transport = self

    def close(self):
        self.closed = True

    def abort(self):
        self.closed = True


class ObservedReader(asyncio.StreamReader):
    def __init__(self):
        super().__init__()
        self.started = asyncio.Event()
        self.finished = asyncio.Event()

    async def read(self, size):
        self.started.set()
        try:
            return await super().read(size)
        finally:
            self.finished.set()


class ProxyReaderTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('rtmp_runner_reader', HERE / 'run.py')
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)

    async def test_repeated_eof_retires_reader_tasks(self):
        proxy = self.module.Proxy()
        tracked_counts = []
        for _ in range(3):
            downstream, incoming = asyncio.StreamReader(), asyncio.StreamReader()
            downstream.feed_eof()
            incoming.feed_eof()
            output, upstream = MemoryWriter(), MemoryWriter()
            with mock.patch.object(self.module.asyncio, 'open_connection',
                                   return_value=(incoming, upstream)):
                reader_task = asyncio.create_task(proxy.reader(downstream, output))
                await asyncio.wait_for(reader_task, 1)
            self.assertEqual(proxy.stats()['active'], 0)
            self.assertEqual(proxy.stats()['heldBytes'], 0)
            self.assertTrue(output.closed and upstream.closed)
            tracked_counts.append(len(proxy.tasks))
        self.assertEqual(proxy.accepted, 3)
        self.assertEqual(proxy.closed, 3)
        self.assertEqual(proxy.errors, [])
        self.assertEqual(tracked_counts, [0, 0, 0])

    async def test_close_cancels_and_retires_active_reader(self):
        proxy = self.module.Proxy()
        downstream, incoming = ObservedReader(), ObservedReader()
        output, upstream = MemoryWriter(), MemoryWriter()
        with mock.patch.object(self.module.asyncio, 'open_connection',
                               return_value=(incoming, upstream)):
            reader_task = asyncio.create_task(proxy.reader(downstream, output))
            await asyncio.wait_for(asyncio.gather(downstream.started.wait(),
                                                 incoming.started.wait()), 1)
            self.assertEqual(proxy.stats()['active'], 1)
            self.assertEqual(proxy.tasks, {reader_task})
            cleanup = await proxy.close()
        self.assertTrue(cleanup['complete'], cleanup)
        self.assertEqual(cleanup['pendingTasks'], 0)
        self.assertTrue(reader_task.done())
        self.assertTrue(downstream.finished.is_set() and incoming.finished.is_set())
        self.assertTrue(output.closed and upstream.closed)
        self.assertEqual(proxy.stats()['active'], 0)
        self.assertEqual(proxy.stats()['heldBytes'], 0)
        self.assertEqual(proxy.errors, [])
        self.assertEqual(len(proxy.tasks), 0)


class RunnerTest(unittest.TestCase):
    def run_case(self, mode, expected_exit, outcome):
        with tempfile.TemporaryDirectory(prefix='yl-rtmp-runner-test-') as root:
            root = Path(root)
            record, output = root / 'command.json', root / 'runner.log'
            proc = None
            receipt_path = None
            with output.open('w') as log:
                try:
                    proc = subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve()), 'runner', mode, str(record)], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    end = time.monotonic() + 12
                    while not record.exists() and proc.poll() is None and time.monotonic() < end:
                        time.sleep(.02)
                    self.assertTrue(record.exists(), output.read_text())
                    owned = json.loads(record.read_text())
                    if mode == 'cancel':
                        proc.send_signal(signal.SIGTERM)
                    actual = proc.wait(timeout=20)
                    self.assertEqual(actual, expected_exit, output.read_text())
                    if mode in ('exited', 'resistant', 'reader'):
                        self.assertFalse(group_exists(owned['group']), f'owned command group leaked: {owned}')
                    paths = [line.split(': ', 1)[1] for line in output.read_text().splitlines() if line.startswith('RTMP acceptance logs: ')]
                    self.assertEqual(len(paths), 1, output.read_text())
                    receipt_path = Path(paths[0]) / 'proxy.json'
                    self.assertTrue(receipt_path.exists(), f'{mode} missing final receipt: {output.read_text()}')
                    receipt = json.loads(receipt_path.read_text())
                    self.assertEqual(receipt['outcome']['kind'], outcome)
                    self.assertEqual(receipt['outcome']['commandExitCode'], expected_exit if mode in ('success', 'nonzero', 'exited', 'reader') else None)
                    self.assertTrue(receipt['cleanup']['complete'], receipt)
                    self.assertEqual(receipt['cleanup']['proxy']['pendingTasks'], 0)
                    self.assertEqual(receipt['active'], 0)
                    self.assertEqual(receipt['heldBytes'], 0)
                    self.assertFalse(group_exists(owned['group']), f'owned command group leaked: {owned}')
                    if mode == 'resistant':
                        groups = receipt['cleanup']['processGroups']
                        self.assertTrue(next(g for g in groups if g['pgid'] == owned['group'])['killSent'])
                    print(f'{mode}: exit={actual} receipt={receipt_path}', flush=True)
                finally:
                    if record.exists():
                        bounded_remove_group(json.loads(record.read_text())['group'])
                    # Signal the owned runner first so its finally can close peers.
                    if proc is not None and proc.poll() is None:
                        proc.terminate()
                        try:
                            proc.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            bounded_remove_group(proc.pid)
                            proc.wait(timeout=3)

    def test_permission_probe_waits_for_confirmed_group_exit(self):
        spec = importlib.util.spec_from_file_location('rtmp_runner_probe', HERE / 'run.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        # No OS signal is sent by this unit probe. A transient permission result
        # is not evidence of group disappearance; the next read-only probe is.
        with mock.patch.object(module.os, 'killpg', side_effect=[PermissionError(), ProcessLookupError()]) as probe:
            self.assertTrue(asyncio.run(module.wait_group_exit(os.getpid(), .1)))
            self.assertEqual(probe.call_count, 2)
            self.assertTrue(all(call.args[1] == 0 for call in probe.call_args_list))

    def test_exited_leader_with_live_reader_cleanup(self):
        self.run_case('reader', 0, 'success')

    def test_success_receipt(self):
        self.run_case('success', 0, 'success')

    def test_nonzero_receipt_preserves_exit(self):
        self.run_case('nonzero', 7, 'nonzero_exit')

    def test_timeout_receipt_preserves_failure(self):
        self.run_case('timeout', 1, 'timeout')

    def test_cancel_receipt_preserves_cancellation(self):
        self.run_case('cancel', 1, 'cancelled')

    def test_exited_leader_descendant_cleanup(self):
        self.run_case('exited', 0, 'success')

    def test_term_resistant_descendant_cleanup(self):
        self.run_case('resistant', 1, 'timeout')


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'runner':
        raise SystemExit(runner_fixture(sys.argv[2], sys.argv[3]))
    if len(sys.argv) > 1 and sys.argv[1] == 'command':
        raise SystemExit(command_fixture(sys.argv[2], sys.argv[3]))
    unittest.main()
