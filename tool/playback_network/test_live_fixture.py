import hashlib
import http.client
from pathlib import Path
import shutil
import tempfile
import threading
import time
import unittest

from live_fixture import LiveFixture, SOURCE_SHA256
from network_profile import Profile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'tool/consumer_fixtures/apple_flutter/Resources/h264_aac.flv'


class LiveFixtureTests(unittest.TestCase):
    def test_source_identity_is_checked_before_starting_children(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'wrong.flv'
            source.write_bytes(b'not the owned fixture')
            with self.assertRaises(ValueError):
                LiveFixture('flv', source, Path(temp) / 'run', 'identity', 'ffmpeg')
            self.assertFalse((Path(temp) / 'run').exists())

    @unittest.skipUnless(shutil.which('ffmpeg'), 'FFmpeg required for owned stream test')
    def test_finite_stream_cleanup_and_first_get_clock(self):
        with tempfile.TemporaryDirectory() as temp:
            fixture = LiveFixture('flv', SOURCE, Path(temp) / 'run', 'cleanup', shutil.which('ffmpeg'))
            with fixture:
                client = http.client.HTTPConnection('127.0.0.1', fixture.port, timeout=5)
                client.request('HEAD', '/live.flv')
                response = client.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.getheader('X-Yl-Timeline-State'), 'pending')
                response.read()
                client.request('GET', '/../private.flv')
                response = client.getresponse()
                self.assertEqual(response.status, 404)
                response.read()
                self.assertFalse(fixture.started)
                client.request('GET', '/live.flv')
                response = client.getresponse()
                self.assertEqual(response.read(3), b'FLV')
                self.assertEqual(response.getheader('X-Yl-Media-SHA256'), SOURCE_SHA256)
                self.assertTrue(fixture.started)
                self.assertTrue(any(p.poll() is None for p in fixture.children))
                # Exiting must cancel a stream even while its reader remains open.
            client.close()
            self.assertTrue(all(p.poll() is not None for p in fixture.children))
            self.assertFalse(fixture.thread.is_alive())
            self.assertTrue(fixture.receipt['cleaned'])
            self.assertGreater(fixture.receipt['requests'][0]['bytes'], 0)

    @unittest.skipUnless(shutil.which('ffmpeg'), 'FFmpeg required for owned stream test')
    def test_shutdown_interrupts_zero_bandwidth(self):
        with tempfile.TemporaryDirectory() as temp:
            profile = Profile({'id': 'owned-stall-v1', 'steps': [
                {'atMs': 0, 'bytesPerSecond': 0, 'latencyMs': 0}]})
            fixture = LiveFixture('flv', SOURCE, Path(temp) / 'run', 'stall', shutil.which('ffmpeg'), profile=profile)
            with fixture:
                client = http.client.HTTPConnection('127.0.0.1', fixture.port, timeout=5)
                client.request('GET', '/live.flv')
                response = client.getresponse()
                self.assertEqual(response.status, 200)
                time.sleep(.1)
                start = time.monotonic()
            client.close()
            self.assertLess(time.monotonic() - start, 4)
            self.assertTrue(fixture.receipt['cleaned'])


if __name__ == '__main__':
    unittest.main()
