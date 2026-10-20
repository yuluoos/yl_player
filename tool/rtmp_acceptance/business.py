#!/usr/bin/env python3
"""Provide owned P05 M3U/JS inputs while the RTMP runner owns media and faults.

python3 tool/rtmp_acceptance/business.py -- flutter test \
  integration_test/live_subscription_playback_test.dart -d macos --no-pub
Run from the TVS root. Android callers must arrange loopback forwarding for
19351, 19352 and 19353; this tool never changes a device or another service.
"""
import asyncio
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile


class OwnedSubscriptionFixture:
    def __init__(self, port=19353):
        self.port = port
        self.server = None
        self.tasks = set()
        self.writers = set()
        self.counts = dict(subscription=0, script=0, rejected=0)
        self.cleaned = False

    async def start(self):
        self.server = await asyncio.start_server(self.serve, '127.0.0.1', self.port, limit=8192)
        self.port = self.server.sockets[0].getsockname()[1]
        self.subscription = (
            '#EXTM3U\n#EXTINF:-1,Owned RTMP\n'
            'rtmp://127.0.0.1:19351/live/owned\n'
            '#EXTINF:-1,Owned JavaScript RTMP\n'
            f'javascript://http://127.0.0.1:{self.port}/source.js\n'
        ).encode()
        self.sha256 = hashlib.sha256(self.subscription).hexdigest()

    def flutter_arguments(self, run):
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', run):
            raise ValueError('Invalid owned run identity')
        return [
            '--dart-define=P05_OWNED=true',
            '--dart-define=P05_RUN=' + run,
            f'--dart-define=P05_SUBSCRIPTION=http://127.0.0.1:{self.port}/owned.m3u',
            '--dart-define=P05_SUBSCRIPTION_SHA256=' + self.sha256,
            '--dart-define=P05_RTMP_CONTROL=http://127.0.0.1:19352',
        ]

    async def serve(self, reader, writer):
        if len(self.tasks) >= 8:
            writer.close()
            return
        task = asyncio.current_task()
        self.tasks.add(task)
        self.writers.add(writer)
        try:
            request = await asyncio.wait_for(reader.readuntil(b'\r\n\r\n'), 3)
            if len(request) > 8192:
                return
            line = request.split(b'\r\n', 1)[0]
            if line == b'GET /owned.m3u HTTP/1.1':
                key, content_type, body = 'subscription', b'application/x-mpegURL', self.subscription
            elif line == b'GET /source.js HTTP/1.1':
                key, content_type, body = 'script', b'application/javascript', b'function main(){return {url:"rtmp://127.0.0.1:19351/live/owned"};}'
            else:
                key, content_type, body = 'rejected', b'text/plain', b'Not found'
            self.counts[key] += 1
            status = b'404 Not Found' if key == 'rejected' else b'200 OK'
            writer.write(b'HTTP/1.1 ' + status + b'\r\nContent-Type: ' + content_type +
                         b'\r\nConnection: close\r\nContent-Length: ' + str(len(body)).encode() +
                         b'\r\n\r\n' + body)
            await asyncio.wait_for(writer.drain(), 3)
        except (ConnectionError, asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            pass
        finally:
            writer.close()
            self.writers.discard(writer)
            self.tasks.discard(task)

    async def close(self):
        if self.server is not None:
            self.server.close()
        for writer in list(self.writers):
            writer.close()
            writer.transport.abort()
        tasks = list(self.tasks)
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.wait_for(asyncio.gather(*tasks, return_exceptions=True), 2)
        if self.server is not None:
            await asyncio.wait_for(self.server.wait_closed(), 2)
        self.cleaned = not self.tasks and not self.writers

    def receipt(self):
        return dict(schemaVersion=1, requests=dict(self.counts),
                    activeRequests=len(self.tasks), cleanupCompleted=self.cleaned,
                    subscriptionSha256=getattr(self, 'sha256', None),
                    physicalAudioVideoVerified=False)


async def main(command):
    if not command or any(
            arg.startswith(('--dart-define=P05_', '-DP05_', '--dart-define-from-file')) or
            (arg.startswith('P05_') and index > 0 and command[index - 1] in ('--dart-define', '-D'))
            for index, arg in enumerate(command)):
        raise ValueError('Expected a Flutter test command without P05 overrides')
    # Import only for the orchestration path; fixture unit tests do not need
    # MediaMTX or FFmpeg and cannot silently skip missing prerequisites.
    import run as rtmp
    fixture = OwnedSubscriptionFixture()
    logs = Path(tempfile.mkdtemp(prefix='p05-business-'))
    print('P05 business receipt:', logs / 'business.json', flush=True)
    outcome = 'error'
    try:
        await fixture.start()
        result = await rtmp.main(command + fixture.flutter_arguments(logs.name))
        outcome = 'success' if result == 0 else 'nonzero_exit'
        return result
    except asyncio.CancelledError:
        outcome = 'cancelled'
        raise
    finally:
        cleanup_error = None
        try:
            await fixture.close()
        except BaseException as error:
            cleanup_error = error
        finally:
            receipt = fixture.receipt()
            receipt['commandOutcome'] = outcome
            if cleanup_error is not None:
                receipt['cleanupCompleted'] = False
                receipt['cleanupErrorType'] = type(cleanup_error).__name__
            (logs / 'business.json').write_text(json.dumps(receipt, indent=2) + '\n')
        # Preserve an in-flight child exception/cancellation/nonzero result.
        # A successful command must still fail when its cleanup did not finish.
        if cleanup_error is not None and outcome == 'success':
            raise cleanup_error


if __name__ == '__main__':
    command = sys.argv[1:]
    if command[:1] == ['--']:
        command = command[1:]
    raise SystemExit(asyncio.run(main(command)))
