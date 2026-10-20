"""Exact virtual-time shaping and real loopback response contract tests."""
import hashlib
import http.client
import io
import json
import socket
from pathlib import Path
import tempfile
import threading
import time
import unittest

try:
    import network_profile as net
except ModuleNotFoundError:
    net = None


class Clock:
    def __init__(self):
        self.value = 0.0

    def now(self):
        return self.value

    def sleep(self, seconds):
        assert seconds > 0
        self.value += seconds


def profile(*steps):
    return {"id": "test-v1", "steps": list(steps)}


def step(at=0, rate=1000, latency=0, disconnect=False):
    return dict(atMs=at, bytesPerSecond=rate, latencyMs=latency,
                disconnect=disconnect)


class ShapingTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(net, "network-profile tool is not implemented")
        self.clock = Clock()

    def shaper(self, *steps):
        return net.Shaper(net.Profile(profile(*steps)), self.clock.now,
                          self.clock.sleep)

    def test_transfer_crosses_rate_boundary_without_resetting_timeline(self):
        s = self.shaper(step(), step(1000, 100))
        s.consume(1100, deadline=10)
        self.assertAlmostEqual(self.clock.value, 2)
        s.consume(100, deadline=10)
        self.assertAlmostEqual(self.clock.value, 3)

    def test_stall_and_recovery_do_not_accumulate_burst_credit(self):
        s = self.shaper(step(), step(500, 0), step(1500, 1000))
        s.consume(1000, deadline=10)
        self.assertAlmostEqual(self.clock.value, 2)

    def test_disconnect_terminates_active_transfer_then_recovers(self):
        s = self.shaper(step(), step(500, 0, disconnect=True), step(1500))
        with self.assertRaises(net.Disconnected):
            s.consume(1000, deadline=10)
        self.assertAlmostEqual(self.clock.value, .5)
        self.clock.value = 1.5
        s.consume(100, deadline=10)
        self.assertAlmostEqual(self.clock.value, 1.6)

    def test_latency_is_request_scoped_but_drop_interrupts_wait(self):
        s = self.shaper(step(latency=100), step(50, 0, disconnect=True))
        with self.assertRaises(net.Disconnected):
            s.begin(deadline=2)
        self.assertAlmostEqual(self.clock.value, .05)

    def test_permanent_stall_stops_at_deadline(self):
        s = self.shaper(step(rate=0))
        with self.assertRaises(TimeoutError):
            s.consume(1, deadline=2)
        self.assertAlmostEqual(self.clock.value, 2)

    def test_invalid_profiles_reject_ambiguous_or_unbounded_values(self):
        invalid = [[], [step(1)], [step(), step()], [step(rate=-1)],
                   [step(latency=True)], [step(rate=float('nan'))],
                   [dict(step(), surprise=1)], [step(disconnect='false')],
                   [step(at=0.5)], [step(rate=10**12)]]
        for steps in invalid:
            with self.subTest(steps=steps), self.assertRaises(ValueError):
                net.Profile(profile(*steps))

    def test_repeated_virtual_runs_are_identical(self):
        runs = []
        for _ in range(2):
            self.clock = Clock()
            s = self.shaper(step(latency=40), step(1000, 100, 200),
                            step(2500, 1000))
            values = []
            for size in [500, 1000, 500]:
                s.begin(deadline=10)
                s.consume(size, deadline=10)
                values.append(round(self.clock.value, 6))
            runs.append(values)
        # Request 2 starts at .58: 420 bytes before 1s, 150 before
        # recovery at 2.5s, then 430 bytes at 1000 B/s => 2.93s.
        self.assertEqual(runs, [[.54, 2.93, 3.43], [.54, 2.93, 3.43]])


class ServerTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(net, "network-profile tool is not implemented")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.payload = b'0123456789' * 30
        (self.root / 'segment.m4s').write_bytes(self.payload)
        (self.root / 'SHA256SUMS').write_text(
            hashlib.sha256(self.payload).hexdigest() + '  ./segment.m4s\n')
        self.log = io.StringIO()

    def start(self, steps=None, clock=None, **options):
        p = net.Profile(profile(*(steps or [step(rate=1000000)])))
        kwargs = {} if clock is None else dict(now=clock.now, sleep=clock.sleep)
        self.server = net.make_server(self.root, p, self.log, port=0, **kwargs, **options)
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={'poll_interval': .01})
        self.thread.start()
        self.addCleanup(self.close)

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.assertFalse(self.thread.is_alive())

    def request(self, path='/segment.m4s', headers=None, method='GET'):
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port,
                                         timeout=2)
        try:
            conn.request(method, path, headers=headers or {})
            response = conn.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            conn.close()

    def records(self):
        # A response EOF can precede its handler's final log append.
        self.server.wait_handlers()
        return [json.loads(line) for line in self.log.getvalue().splitlines()]

    def test_get_range_head_and_actual_byte_log(self):
        self.start()
        self.assertEqual(self.request()[2], self.payload)
        status, headers, body = self.request(headers={'Range': 'bytes=10-19'})
        self.assertEqual((status, body, headers['Content-Range']),
                         (206, b'0123456789', 'bytes 10-19/300'))
        self.assertEqual(self.request(method='HEAD')[2], b'')
        records = self.records()
        self.assertEqual([r['bodyBytesWritten'] for r in records], [300, 10, 0])
        self.assertTrue(all(r['outcome'] == 'complete' for r in records))

    def test_trace_accounts_successful_writes_in_each_profile_phase(self):
        self.start([step(rate=1000), step(100, 1000)], clock=Clock())
        self.assertEqual(self.request()[2], self.payload)
        row = self.records()[0]
        self.assertEqual(row.get('phaseBytesWritten'), [0, 300])
        self.assertEqual(sum(row['phaseBytesWritten']), row['bodyBytesWritten'])
        self.assertEqual(row.get('phaseBoundariesMs'), [0, 100])

    def test_suffix_open_range_and_invalid_range(self):
        self.start()
        for value, status, expected in [('bytes=-3', 206, b'789'),
                                         ('bytes=298-', 206, b'89'),
                                         ('bytes=300-', 416, b''),
                                         ('bytes=0-1,4-5', 416, b'')]:
            result = self.request(headers={'Range': value})
            self.assertEqual((result[0], result[2]), (status, expected))

    def test_query_and_headers_never_enter_trace(self):
        self.start()
        self.request('/segment.m4s?token=secret-value',
                     {'Authorization': 'Bearer secret-value'})
        self.records()
        self.assertNotIn('secret-value', self.log.getvalue())
        self.assertEqual(json.loads(self.log.getvalue())['asset'], 'segment.m4s')

    def test_unknown_and_traversal_paths_are_not_served_or_logged(self):
        self.start()
        for path in ['/../private-token', '/%2e%2e/private-token', '/SHA256SUMS',
                     '/unknown-secret', '/%00']:
            self.assertEqual(self.request(path)[0], 404)
        self.records()
        self.assertNotIn('private-token', self.log.getvalue())
        self.assertNotIn('unknown-secret', self.log.getvalue())

    def test_inventory_rejects_tampering_symlinks_and_duplicates(self):
        (self.root / 'segment.m4s').write_bytes(b'tampered')
        with self.assertRaises(ValueError):
            net.load_assets(self.root)
        (self.root / 'segment.m4s').unlink()
        (self.root / 'outside').write_bytes(self.payload)
        (self.root / 'segment.m4s').symlink_to(self.root / 'outside')
        with self.assertRaises(ValueError):
            net.load_assets(self.root)
        (self.root / 'segment.m4s').unlink()
        (self.root / 'segment.m4s').write_bytes(self.payload)
        inventory = self.root / 'SHA256SUMS'
        inventory.write_text(inventory.read_text() * 2)
        with self.assertRaises(ValueError):
            net.load_assets(self.root)

    def test_drop_mid_body_logs_only_completed_writes(self):
        self.payload = b'x' * 3000
        (self.root / 'segment.m4s').write_bytes(self.payload)
        (self.root / 'SHA256SUMS').write_text(
            hashlib.sha256(self.payload).hexdigest() + '  ./segment.m4s\n')
        clock = Clock()
        self.start([step(rate=1000), step(1100, 0, disconnect=True)], clock)
        with self.assertRaises(http.client.IncompleteRead):
            self.request()
        row = self.records()[0]
        self.assertEqual(row['outcome'], 'disconnected')
        self.assertEqual(row['bodyBytesWritten'], 1024)
        self.assertEqual(row['endMs'], 1100)

    def test_parallel_requests_share_bandwidth_and_have_unique_ids(self):
        self.start([step(rate=10000)])
        barrier = threading.Barrier(3)
        responses = []
        def fetch():
            barrier.wait()
            responses.append(self.request()[2])
        workers = [threading.Thread(target=fetch) for _ in range(2)]
        for worker in workers:
            worker.start()
        started = time.monotonic()
        barrier.wait()
        for worker in workers:
            worker.join(timeout=2)
            self.assertFalse(worker.is_alive())
        self.assertEqual(responses, [self.payload, self.payload])
        self.assertGreaterEqual(time.monotonic() - started, .06)
        rows = self.records()
        self.assertEqual(len({r.get('requestId') for r in rows}), 2)

    def test_admission_limit_is_counted_without_unbounded_log_growth(self):
        self.start()
        self.server.requests = 10000
        with self.assertRaises((http.client.RemoteDisconnected, ConnectionError)):
            self.request()
        self.assertEqual(self.records(), [])
        self.assertEqual(self.server.rejected_requests, 1)

    def test_incomplete_headers_have_absolute_connection_deadline(self):
        self.start()
        self.server.connection_timeout = .05
        with socket.create_connection(('127.0.0.1', self.server.server_port), timeout=.5) as client:
            client.sendall(b'GET /segment.m4s HTTP/1.0\r\nX-Incomplete: ')
            self.assertEqual(client.recv(4096), b'')
        self.assertTrue(self.server.wait_handlers())

    def test_shutdown_wakes_incomplete_header_reader(self):
        self.start()
        with socket.create_connection(('127.0.0.1', self.server.server_port), timeout=.5) as client:
            client.sendall(b'GET /segment.m4s HTTP/1.0\r\nX-Incomplete: ')
            # Wait for admission, not for a guessed scheduling delay.
            with self.server.handlers:
                self.assertTrue(self.server.handlers.wait_for(lambda: self.server.active == 1, timeout=.5))
            self.server.shutdown()
            started = time.monotonic()
            self.server.server_close()
            self.assertLess(time.monotonic() - started, .5)
            self.assertEqual(client.recv(4096), b'')

    def test_owned_fixture_inventory_and_versioned_profiles(self):
        directory = Path(__file__).resolve().parent
        profiles = net.load_profiles(directory / 'profiles.json')
        self.assertIn('down-and-recover-v1', profiles)
        assets = net.load_assets(directory.parents[1] /
            'packages/yl_player/example/assets/test_media/dash_variants')
        self.assertIn('manifest.mpd', assets)
        self.assertIn('period1/init-2.m4s', assets)

    def test_deferred_clock_arms_once_and_head_identifies_run_without_starting(self):
        clock = Clock()
        self.start(clock=clock, start_on_first_get=True, run_id='capture-1')
        clock.value = 60
        _, headers, _ = self.request(method='HEAD')
        self.assertEqual(headers['X-Yl-Timeline-State'], 'pending')
        self.assertEqual(headers['X-Yl-Run-Id'], 'capture-1')
        self.assertEqual(headers['X-Yl-Asset-Sha256'], hashlib.sha256(self.payload).hexdigest())
        self.assertEqual(clock.value, 60)
        self.request()
        clock.value = 62
        self.request()
        rows = self.records()
        self.assertIsNone(rows[0]['startMs'])
        self.assertEqual(rows[1]['startMs'], 0)
        self.assertEqual(rows[2]['startMs'], 2000)
        self.assertTrue(all(r['runId'] == 'capture-1' for r in rows))


if __name__ == '__main__':
    unittest.main()
