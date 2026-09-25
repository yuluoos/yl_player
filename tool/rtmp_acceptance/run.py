#!/usr/bin/env python3
"""Run a command against the pinned independent peer and bounded reader proxy.

Usage: python3 tool/rtmp_acceptance/run.py -- <command> [args...]
No downloads, process discovery, or product artifact changes. Every child is owned.
"""
import asyncio
from collections import deque
import hashlib
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import tarfile

ROOT = Path(__file__).resolve().parents[2]
PEER = Path('/private/tmp/yl-rtmp-foundation')
CAP = 8 * 1024 * 1024
GROUP_TERM_SECONDS = 5
GROUP_KILL_SECONDS = 2
PROXY_CLOSE_SECONDS = 2


class Proxy:
    def __init__(self):
        self.clients = set()
        self.accepted = 0
        self.closed = 0
        self.hold = False
        self.silent = False
        self.errors = []
        self.history = []
        self.control_clients = 0
        self.peak_held = 0
        self.tasks = set()
        self.control_writers = set()

    def stats(self):
        return dict(accepted=self.accepted, closed=self.closed, active=len(self.clients),
                    heldBytes=sum(c['size'] for c in self.clients), errors=self.errors,
                    history=self.history, peakHeldBytes=self.peak_held)

    async def reader(self, downstream, output):
        if len(self.clients) >= 8:
            output.close()
            return
        reader_task = asyncio.current_task()
        self.tasks.add(reader_task)
        self.accepted += 1
        self.history.append(dict(event='connect', id=self.accepted, time=asyncio.get_running_loop().time()))
        self.history = self.history[-128:]
        client = dict(output=output, upstream=None, size=0, queue=deque(), silent=self.silent)
        # Identity set via wrapper: dictionaries are not hashable.
        client = Client(client)
        self.clients.add(client)
        tasks = []
        try:
            if client['silent']:
                while await downstream.read(65536):
                    pass
                return
            incoming, upstream = await asyncio.open_connection('127.0.0.1', 19350, limit=65536)
            client['upstream'] = upstream

            async def forward_input():
                while data := await downstream.read(65536):
                    upstream.write(data)
                    await upstream.drain()

            async def drain_peer():
                while data := await incoming.read(65536):
                    if client['size'] + len(data) > CAP:
                        raise RuntimeError('held output cap exceeded')
                    client['queue'].append(data)
                    client['size'] += len(data)
                    self.peak_held = max(self.peak_held, client['size'])

            async def deliver():
                while True:
                    if not self.hold and client['queue']:
                        data = client['queue'].popleft()
                        client['size'] -= len(data)
                        output.write(data)
                        await output.drain()
                    else:
                        await asyncio.sleep(.01)

            tasks = [asyncio.create_task(f()) for f in (forward_input, drain_peer, deliver)]
            done, _ = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                task.result()
        except (ConnectionError, asyncio.CancelledError):
            pass
        except Exception as error:
            self.errors.append(type(error).__name__ + ': ' + str(error))
            self.errors = self.errors[-16:]
        finally:
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            output.close()
            if client['upstream']:
                client['upstream'].close()
            self.clients.discard(client)
            self.closed += 1
            self.tasks.discard(reader_task)

    async def control(self, reader, writer):
        if self.control_clients >= 4:
            writer.close()
            return
        task = asyncio.current_task()
        self.tasks.add(task)
        self.control_writers.add(writer)
        self.control_clients += 1
        try:
            request = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 3)
            if len(request) > 8192:
                raise ValueError('request too large')
            route = request.split(b' ')[1].decode()
            if route == '/hold':
                self.hold = True
            elif route == '/release':
                self.hold = False
            elif route == '/silent':
                self.silent = True
            elif route == '/normal':
                self.silent = False
                self.hold = False
            elif route == '/drop':
                for client in list(self.clients):
                    client['output'].close()
                    if client['upstream']:
                        client['upstream'].close()
            elif route != '/stats':
                raise ValueError('unknown operation')
            body = json.dumps(self.stats()).encode()
            writer.write(b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: ' + str(len(body)).encode() + b'\r\n\r\n' + body)
            await writer.drain()
        except (ConnectionError, asyncio.TimeoutError, asyncio.IncompleteReadError):
            pass
        finally:
            self.control_clients -= 1
            self.control_writers.discard(writer)
            self.tasks.discard(task)
            writer.close()

    async def close(self):
        # The listener contexts have closed before this bounded drain. Abort
        # transports too: StreamWriter.close alone can wait on a blocked peer.
        writers = set(self.control_writers)
        for client in self.clients:
            writers.add(client['output'])
            if client['upstream']:
                writers.add(client['upstream'])
        for writer in writers:
            writer.close()
            writer.transport.abort()
        pending = set(self.tasks)
        for task in pending:
            task.cancel()
        if pending:
            _, pending = await asyncio.wait(pending, timeout=PROXY_CLOSE_SECONDS)
        return dict(complete=not pending and not self.clients and self.control_clients == 0,
                    pendingTasks=len(pending), activeReaders=len(self.clients),
                    activeControls=self.control_clients)


class Client(dict):
    __hash__ = object.__hash__
    __eq__ = object.__eq__


def group_exists(pgid):
    try:
        os.killpg(pgid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        # EPERM does not prove absence (it can race group retirement). Keep
        # polling within the same deadline; never call cleanup complete on it.
        return True


async def wait_group_exit(pgid, seconds):
    deadline = asyncio.get_running_loop().time() + seconds
    while group_exists(pgid):
        if asyncio.get_running_loop().time() >= deadline:
            return False
        await asyncio.sleep(.02)
    return True


async def close_owned_group(child):
    # Every child was started with start_new_session=True, so its original PID
    # is the recorded owned PGID even after that leader exits. Never discover
    # groups by port, process name, or unrelated PID.
    pgid = child.pid
    result = dict(pgid=pgid, termSent=False, killSent=False, complete=False)
    try:
        if group_exists(pgid):
            try:
                os.killpg(pgid, signal.SIGTERM)
                result['termSent'] = True
            except ProcessLookupError:
                pass
            if not await wait_group_exit(pgid, GROUP_TERM_SECONDS):
                try:
                    os.killpg(pgid, signal.SIGKILL)
                    result['killSent'] = True
                except ProcessLookupError:
                    pass
                await wait_group_exit(pgid, GROUP_KILL_SECONDS)
        if child.returncode is None:
            await asyncio.wait_for(child.wait(), GROUP_KILL_SECONDS)
        result['groupRemaining'] = group_exists(pgid)
        result['complete'] = not result['groupRemaining'] and child.returncode is not None
    except (OSError, asyncio.TimeoutError) as error:
        result['errorType'] = type(error).__name__
    result['leaderReturnCode'] = child.returncode
    return result


async def main(command):
    fixture = ROOT / 'tool/consumer_fixtures/apple_flutter/Resources/h264_aac.flv'
    assert hashlib.sha256(fixture.read_bytes()).hexdigest() == 'cfe009b1b03b6cacf4ae9f037eed4441a32b99508d4fabccb429bea439cf570b'
    assert hashlib.sha256((PEER / 'mediamtx.tar.gz').read_bytes()).hexdigest() == '25e20ed41611f1f3103b8359585210b29b11b69fa0d9e11bd11b92f7bbcb42ef'
    with tarfile.open(PEER / 'mediamtx.tar.gz') as archive:
        member = archive.extractfile('mediamtx')
        assert member is not None
        assert hashlib.sha256(member.read()).digest() == hashlib.sha256((PEER / 'mediamtx').read_bytes()).digest(), 'extracted binary differs from verified release'
    logs = Path(tempfile.mkdtemp(prefix='app-', dir=PEER))
    print('RTMP acceptance logs:', logs, flush=True)
    children, handles = [], []
    loop = asyncio.get_running_loop()
    owner = asyncio.current_task()
    previous_sigterm = signal.getsignal(signal.SIGTERM)
    loop.add_signal_handler(signal.SIGTERM, owner.cancel)
    proxy = Proxy()
    command_child = None
    outcome = dict(kind='error', commandExitCode=None)

    async def finish():
        cleanup = dict(complete=False, processGroups=[])
        try:
            cleanup['proxy'] = await proxy.close()
        except Exception as error:
            cleanup['proxy'] = dict(complete=False, errorType=type(error).__name__,
                                    pendingTasks=len(proxy.tasks), activeReaders=len(proxy.clients),
                                    activeControls=proxy.control_clients)
        for child in reversed(children):
            cleanup['processGroups'].append(await close_owned_group(child))
        for handle in handles:
            handle.close()
        cleanup['complete'] = cleanup['proxy']['complete'] and all(
            group['complete'] for group in cleanup['processGroups'])
        return cleanup

    async def spawn(args, name):
        log = (logs / name).open('wb')
        handles.append(log)
        child = await asyncio.create_subprocess_exec(*args, stdout=log, stderr=asyncio.subprocess.STDOUT, start_new_session=True)
        children.append(child)
        return child
    try:
        config = logs / 'peer.yml'
        config.write_text('logLevel: info\nrtsp: false\nrtmp: true\nrtmpAddress: 127.0.0.1:19350\nhls: false\nwebrtc: false\nsrt: false\nmoq: false\napi: false\nmetrics: false\npprof: false\nplayback: false\npaths:\n  all_others:\n')
        peer = await spawn([str(PEER / 'mediamtx'), str(config)], 'peer.log')
        await asyncio.sleep(1)
        assert peer.returncode is None, 'peer start failed; no process will be killed by port'
        for path, extra in [('owned', []), ('video', ['-an'])]:
            pub = await spawn(['/opt/homebrew/bin/ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'warning', '-re', '-stream_loop', '-1', '-i', str(fixture), '-c', 'copy', *extra, '-f', 'flv', 'rtmp://127.0.0.1:19350/live/' + path], path + '.log')
            await asyncio.sleep(1)
            assert pub.returncode is None, 'publisher start failed'
        async with await asyncio.start_server(proxy.reader, '127.0.0.1', 19351, limit=65536), await asyncio.start_server(proxy.control, '127.0.0.1', 19352, limit=8192):
            command_child = await asyncio.create_subprocess_exec(*command, start_new_session=True)
            children.append(command_child)
            result = await asyncio.wait_for(command_child.wait(), 1200)
            outcome.update(kind='success' if result == 0 else 'nonzero_exit', commandExitCode=result)
            return result
    except asyncio.CancelledError:
        outcome.update(kind='cancelled')
        raise
    except asyncio.TimeoutError:
        outcome.update(kind='timeout')
        raise
    except BaseException as error:
        outcome.update(kind='error', errorType=type(error).__name__)
        raise
    finally:
        # Shield only bounded cleanup, never playback or the command deadline.
        # Repeated cancellation still propagates after the final receipt.
        cleanup_task = asyncio.create_task(finish())
        cancelled_during_cleanup = False
        while not cleanup_task.done():
            try:
                await asyncio.shield(cleanup_task)
            except asyncio.CancelledError:
                cancelled_during_cleanup = True
                outcome.update(kind='cancelled')
        try:
            cleanup = cleanup_task.result()
        except Exception as error:
            cleanup = dict(complete=False, errorType=type(error).__name__)
        # Snapshot after the shield finishes, so cancellation arriving during
        # cleanup cannot leave a success receipt with a cancelled outer task.
        receipt = proxy.stats()
        receipt.update(outcome=dict(outcome), cleanup=cleanup,
                       observedCommandReturnCode=command_child.returncode if command_child else None)
        try:
            (logs / 'proxy.json').write_text(json.dumps(receipt, indent=2))
        except OSError as error:
            # A disk error must not replace the original command semantics.
            print('Acceptance receipt write failed:', type(error).__name__, file=sys.stderr, flush=True)
        loop.remove_signal_handler(signal.SIGTERM)
        signal.signal(signal.SIGTERM, previous_sigterm)
        if cancelled_during_cleanup:
            raise asyncio.CancelledError


if __name__ == '__main__':
    args = sys.argv[1:]
    if args and args[0] == '--':
        args = args[1:]
    if not args:
        raise SystemExit('expected command after --')
    raise SystemExit(asyncio.run(main(args)))
