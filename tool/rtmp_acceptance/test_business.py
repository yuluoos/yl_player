"""Bounded owned subscription fixture contracts; no device or external host."""
import asyncio
import hashlib
import importlib.util
import json
import tempfile
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('business', Path(__file__).with_name('business.py'))
business = importlib.util.module_from_spec(spec)
spec.loader.exec_module(business)


class BusinessFixtureTest(unittest.IsolatedAsyncioTestCase):
    async def request(self, fixture, path, method='GET'):
        reader, writer = await asyncio.open_connection('127.0.0.1', fixture.port)
        writer.write(f'{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n'.encode())
        await writer.drain()
        raw = await asyncio.wait_for(reader.read(), 2)
        writer.close()
        await writer.wait_closed()
        return raw.split(b'\r\n\r\n', 1)

    async def test_subscription_hash_and_script_resolve_to_owned_rtmp(self):
        fixture = business.OwnedSubscriptionFixture(port=0)
        await fixture.start()
        try:
            headers, body = await self.request(fixture, '/owned.m3u')
            self.assertIn(b'200 OK', headers)
            self.assertEqual(hashlib.sha256(body).hexdigest(), fixture.sha256)
            self.assertIn(b'rtmp://127.0.0.1:19351/live/owned', body)
            self.assertIn(f'javascript://http://127.0.0.1:{fixture.port}/source.js'.encode(), body)
            _, script = await self.request(fixture, '/source.js')
            self.assertEqual(script, b'function main(){return {url:"rtmp://127.0.0.1:19351/live/owned"};}')
            args = fixture.flutter_arguments('owned-01')
            self.assertIn('--dart-define=P05_SUBSCRIPTION_SHA256=' + fixture.sha256, args)
            self.assertIn('--dart-define=P05_RTMP_CONTROL=http://127.0.0.1:19352', args)
        finally:
            await fixture.close()
        self.assertTrue(fixture.receipt()['cleanupCompleted'])
        self.assertEqual(fixture.receipt()['requests'], {'subscription': 1, 'script': 1, 'rejected': 0})

    async def test_unknown_routes_and_methods_are_rejected_without_echo(self):
        fixture = business.OwnedSubscriptionFixture(port=0)
        await fixture.start()
        try:
            for path, method in [('/private?token=secret', 'GET'), ('/owned.m3u', 'POST')]:
                headers, body = await self.request(fixture, path, method)
                self.assertIn(b'404 Not Found', headers)
                self.assertNotIn(b'secret', body)
            self.assertNotIn('secret', str(fixture.receipt()))
            self.assertEqual(fixture.receipt()['requests']['rejected'], 2)
        finally:
            await fixture.close()

    async def test_close_joins_partial_requests_and_releases_port(self):
        fixture = business.OwnedSubscriptionFixture(port=0)
        await fixture.start()
        reader, writer = await asyncio.open_connection('127.0.0.1', fixture.port)
        writer.write(b'GET /owned.m3u HTTP/1.1\r\n')
        await writer.drain()
        await asyncio.sleep(.01)
        await asyncio.wait_for(fixture.close(), 2)
        self.assertEqual(await asyncio.wait_for(reader.read(), 1), b'')
        self.assertEqual(fixture.receipt()['activeRequests'], 0)
        writer.close()
        await writer.wait_closed()
        listener = await asyncio.start_server(lambda r,w: w.close(), '127.0.0.1', fixture.port)
        listener.close()
        await listener.wait_closed()

    async def test_oversized_header_is_bounded_and_cleanup_succeeds(self):
        fixture = business.OwnedSubscriptionFixture(port=0)
        await fixture.start()
        reader, writer = await asyncio.open_connection('127.0.0.1', fixture.port)
        writer.write(b'GET /' + b'x' * 9000)
        await writer.drain()
        self.assertEqual(await asyncio.wait_for(reader.read(), 2), b'')
        writer.close()
        await writer.wait_closed()
        await fixture.close()
        self.assertTrue(fixture.receipt()['cleanupCompleted'])

    async def test_run_identity_rejects_arbitrary_text(self):
        fixture = business.OwnedSubscriptionFixture(port=0)
        await fixture.start()
        try:
            for value in ['', 'x' * 65, 'private/token']:
                with self.assertRaises(ValueError):
                    fixture.flutter_arguments(value)
        finally:
            await fixture.close()


class BusinessOrchestrationTest(unittest.IsolatedAsyncioTestCase):
    async def test_cleanup_failure_still_writes_safe_receipt_and_preserves_child_error(self):
        fixture = SimpleNamespace(start=AsyncMock(), close=AsyncMock(side_effect=TimeoutError('private-token')),
                                  flutter_arguments=lambda _: [], receipt=lambda: {'cleanupCompleted': False})
        child = AsyncMock(side_effect=ValueError('owned child failure'))
        with tempfile.TemporaryDirectory() as logs, patch.object(business, 'OwnedSubscriptionFixture', return_value=fixture), patch.object(business.tempfile, 'mkdtemp', return_value=logs), patch.dict('sys.modules', {'run': SimpleNamespace(main=child)}):
            with self.assertRaisesRegex(ValueError, 'owned child failure'):
                await business.main(['flutter', 'test'])
            receipt = json.loads((Path(logs) / 'business.json').read_text())
            self.assertEqual(receipt['commandOutcome'], 'error')
            self.assertFalse(receipt['cleanupCompleted'])
            self.assertEqual(receipt['cleanupErrorType'], 'TimeoutError')
            self.assertNotIn('private-token', json.dumps(receipt))

    async def test_successful_child_cannot_mask_cleanup_failure(self):
        fixture = SimpleNamespace(start=AsyncMock(), close=AsyncMock(side_effect=TimeoutError()),
                                  flutter_arguments=lambda _: [], receipt=lambda: {'cleanupCompleted': False})
        with tempfile.TemporaryDirectory() as logs, patch.object(business, 'OwnedSubscriptionFixture', return_value=fixture), patch.object(business.tempfile, 'mkdtemp', return_value=logs), patch.dict('sys.modules', {'run': SimpleNamespace(main=AsyncMock(return_value=0))}):
            with self.assertRaises(TimeoutError):
                await business.main(['flutter', 'test'])
            self.assertFalse(json.loads((Path(logs) / 'business.json').read_text())['cleanupCompleted'])

    async def test_conflicting_define_forms_are_rejected_before_fixture_start(self):
        for args in [['--dart-define=P05_OWNED=false'], ['--dart-define', 'P05_OWNED=false'], ['-DP05_OWNED=false'], ['-D', 'P05_OWNED=false'], ['--dart-define-from-file=owned.json']]:
            with self.subTest(args=args), patch.object(business, 'OwnedSubscriptionFixture') as fixture:
                with self.assertRaises(ValueError):
                    await business.main(['flutter', 'test'] + args)
                fixture.assert_not_called()
