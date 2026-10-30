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

    def test_waiting_for_budget_lock_observes_deadline_and_stop(self):
        for stop in [False,True]:
            with self.subTest(stop=stop):
                shaper=net.Shaper(net.Profile(profile(step())))
                shaper.lock.acquire();done=threading.Event();failures=[];timing=net.RequestTiming(shaper.now)
                def consume():
                    try:shaper.consume(1,deadline=shaper.elapsed()+(.06 if not stop else 10),timing=timing)
                    except Exception as error:failures.append(type(error))
                    finally:done.set()
                worker=threading.Thread(target=consume,daemon=True);worker.start()
                if stop:shaper.stopped.set()
                try:self.assertTrue(done.wait(.5),'A queued request must not wait for the lock owner after cancellation/deadline')
                finally:shaper.lock.release();worker.join(timeout=1)
                self.assertEqual(failures,[net.Disconnected if stop else TimeoutError])
                self.assertEqual(timing.values['queueFailures'],1)
                self.assertEqual(timing.values['holdCalls'],0)

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

    def lifecycle(self):
        self.assertTrue(callable(getattr(self.server, 'connection_lifecycle', None)),
                        'Pre-request connection closures need preserved evidence')
        return self.server.connection_lifecycle()

    def test_opt_in_lifecycle_token_matches_actual_socket_endpoints(self):
        from transaction_connections import connection_token
        from connection_lifecycle import summarize_lifecycle
        key=b'0123456789abcdef'*4
        self.start(connection_key=key)
        conn=socket.create_connection(('127.0.0.1',self.server.server_port),timeout=2)
        expected=connection_token(key,conn.getsockname(),conn.getpeername())
        with self.server.handlers:self.assertTrue(self.server.handlers.wait_for(lambda:self.server.requests==1,timeout=2))
        conn.close();self.assertTrue(self.server.wait_handlers())
        trace=self.lifecycle();self.assertEqual(trace['version'],2)
        self.assertEqual(trace['connections'][0]['connectionToken'],expected)
        self.assertNotIn(key.decode(),json.dumps(trace));self.assertNotIn('127.0.0.1',json.dumps(trace))
        self.assertEqual(summarize_lifecycle(trace,[])['withoutParsedRequest'],[1])

    def test_lifecycle_keeps_headerless_close_and_correlates_normal_request(self):
        self.start()
        conn=socket.create_connection(('127.0.0.1',self.server.server_port),timeout=2)
        with self.server.handlers:self.assertTrue(self.server.handlers.wait_for(lambda:self.server.requests==1,timeout=2))
        conn.close();self.assertTrue(self.server.wait_handlers())
        self.assertEqual(self.request(headers={'Authorization':'secret-value'})[2],self.payload)
        rows=self.records();trace=self.lifecycle()
        self.assertEqual(trace['acceptedCount'],2);self.assertEqual(trace['rejectedCount'],0)
        self.assertEqual(trace['connections'][0]['requestIds'],[])
        self.assertEqual(trace['connections'][1]['requestIds'],[rows[0]['requestId']])
        self.assertEqual(trace['connections'][0]['closeReason'],'handlerEnded')
        self.assertNotIn('secret',json.dumps(trace));self.assertNotIn('127.0.0.1',json.dumps(trace))
        from connection_lifecycle import summarize_lifecycle
        summary=summarize_lifecycle(trace,rows)
        self.assertEqual(summary['withoutParsedRequest'],[1]);self.assertTrue(summary['complete'])

    def test_lifecycle_records_admission_rejection_before_any_request(self):
        self.start();peers=[]
        try:
            for n in range(8):
                peers.append(socket.create_connection(('127.0.0.1',self.server.server_port),timeout=2))
                with self.server.handlers:self.assertTrue(self.server.handlers.wait_for(lambda:self.server.active==n+1,timeout=2))
            extra=socket.create_connection(('127.0.0.1',self.server.server_port),timeout=2)
            try:self.assertEqual(extra.recv(1),b'')
            finally:extra.close()
        finally:
            for peer in peers:peer.close()
        self.assertTrue(self.server.wait_handlers());trace=self.lifecycle()
        self.assertEqual(trace['acceptedCount'],8);self.assertEqual(trace['rejectedCount'],1)
        self.assertEqual(trace['rejections'][0]['reason'],'activeLimit')
        self.assertEqual(trace['rejections'][0]['active'],8)
        self.assertEqual(self.records(),[])

    def test_lifecycle_keeps_full_rejection_count_when_samples_are_bounded(self):
        self.start();peers=[]
        try:
            for n in range(8):
                peers.append(socket.create_connection(('127.0.0.1',self.server.server_port),timeout=2))
                with self.server.handlers:self.assertTrue(self.server.handlers.wait_for(lambda:self.server.active==n+1,timeout=2))
            for _ in range(33):
                conn=socket.create_connection(('127.0.0.1',self.server.server_port),timeout=2)
                try:self.assertEqual(conn.recv(1),b'')
                finally:conn.close()
        finally:
            for peer in peers:peer.close()
        self.assertTrue(self.server.wait_handlers());trace=self.lifecycle()
        self.assertEqual(trace['rejectedCount'],33);self.assertEqual(len(trace['rejections']),32)
        self.assertEqual(trace['droppedRejections'],1)
        from connection_lifecycle import summarize_lifecycle
        self.assertFalse(summarize_lifecycle(trace,[])['complete'])

    def test_lifecycle_records_shutdown_before_header_read_returns(self):
        self.start();conn=socket.create_connection(('127.0.0.1',self.server.server_port),timeout=2)
        try:
            with self.server.handlers:self.assertTrue(self.server.handlers.wait_for(lambda:self.server.active==1,timeout=2))
            self.server.shutdown();self.server.server_close()
            self.assertEqual(conn.recv(1),b'')
        finally:conn.close()
        self.assertEqual(self.lifecycle()['connections'][0]['closeReason'],'serverShutdown')

    def test_lifecycle_distinguishes_deadline_from_unobserved_peer_close(self):
        self.start();self.server.connection_timeout=.05
        conn=socket.create_connection(('127.0.0.1',self.server.server_port),timeout=2)
        try:self.assertEqual(conn.recv(1),b'')
        finally:conn.close()
        self.assertTrue(self.server.wait_handlers());trace=self.lifecycle()
        self.assertEqual(trace['connections'][0]['closeReason'],'absoluteDeadline')
        self.assertEqual(trace['connections'][0]['requestIds'],[])
        self.assertGreaterEqual(trace['connections'][0]['closedSeconds'],trace['connections'][0]['acceptedSeconds'])

    def test_actual_server_records_oversleep_without_increasing_rate_credit(self):
        class Oversleep(Clock):
            def sleep(self,seconds):super().sleep(seconds);self.value+=.01
        self.start(steps=[step(rate=1000,latency=40)],clock=Oversleep())
        self.assertEqual(self.request()[2],self.payload)
        rows=self.records();timing=rows[0]['serverTiming']
        self.assertAlmostEqual(timing['latencySeconds'],.05)
        self.assertAlmostEqual(timing['sleepRequestedSeconds'],.3)
        self.assertAlmostEqual(timing['sleepSeconds'],.36)
        self.assertAlmostEqual(timing['holdSeconds'],.36)
        self.assertEqual(timing['headerWriteCalls'],1)
        self.assertEqual(timing['bodyWriteCalls'],1)
        self.assertEqual(timing['queueCalls'],1)
        from server_timing import summarize_server_timing
        self.assertTrue(summarize_server_timing(rows)['complete'])

    def test_http11_persistence_reuses_socket_and_preserves_range_head(self):
        self.start(connection_mode='http11-keepalive')
        conn = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=2)
        try:
            sockets=[]
            for method,headers,want in [('GET',{},self.payload),('HEAD',{},b''),
                    ('GET',{'Range':'bytes=10-19'},b'0123456789')]:
                conn.request(method,'/segment.m4s',headers=headers)
                response=conn.getresponse();self.assertEqual(response.version,11)
                self.assertEqual(response.read(),want);sockets.append(conn.sock)
            self.assertTrue(all(s is sockets[0] and s is not None for s in sockets))
        finally:conn.close()
        rows=self.records()
        self.assertEqual([r['connectionRequestIndex'] for r in rows],[1,2,3])
        self.assertEqual(len({r['connectionId'] for r in rows}),1)
        self.assertTrue(all(r['connectionMode']=='http11-keepalive' for r in rows))
        self.assertEqual([r['bodyBytesWritten'] for r in rows],[300,0,10])

    def test_http11_close_is_same_protocol_without_persistence(self):
        self.start(connection_mode='http11-close')
        conn=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=2)
        try:
            for _ in range(2):
                conn.request('GET','/segment.m4s');response=conn.getresponse()
                self.assertEqual(response.version,11);self.assertEqual(response.read(),self.payload)
                self.assertIsNone(conn.sock)
        finally:conn.close()
        rows=self.records();self.assertEqual(len({r['connectionId'] for r in rows}),2)
        self.assertEqual([r['connectionRequestIndex'] for r in rows],[1,1])

    def test_persistent_peer_close_and_request_budget_are_bounded(self):
        self.start(connection_mode='http11-keepalive')
        self.server.next_record_id=9999
        conn=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=2)
        try:
            conn.request('GET','/segment.m4s');self.assertEqual(conn.getresponse().read(),self.payload)
            conn.request('GET','/segment.m4s')
            with self.assertRaises(http.client.RemoteDisconnected):conn.getresponse()
        finally:conn.close()
        rows=self.records();self.assertEqual(len(rows),1);self.assertEqual(rows[0]['requestId'],10000)
        trace=self.lifecycle();self.assertEqual(trace['connections'][0].get('unrecordedRequests'),1)
        self.assertEqual(trace['connections'][0]['closeReason'],'requestRecordLimit')

    def test_persistent_client_can_request_close(self):
        self.start(connection_mode='http11-keepalive')
        self.assertEqual(self.request(headers={'Connection':'close'})[2],self.payload)
        self.assertTrue(self.server.wait_handlers())
        self.assertEqual(self.records()[0]['connectionMode'],'http11-keepalive')

    def test_connection_mode_rejects_unknown_and_default_stays_legacy(self):
        with self.assertRaises(ValueError):self.start(connection_mode='unexpected')
        self.start();status,headers,body=self.request()
        self.assertEqual(headers['Connection'],'close');self.assertEqual(body,self.payload)
        self.assertEqual(self.records()[0]['connectionMode'],'close')

    def test_active_clock_header_is_bracketable_and_head_does_not_arm(self):
        clock = Clock()
        self.start(clock=clock, start_on_first_get=True, run_id='clock-run')
        headers = self.request(method='HEAD')[1]
        self.assertNotIn('X-Yl-Elapsed-Us', headers)
        self.request()
        clock.value += 2
        headers = self.request(method='HEAD')[1]
        self.assertEqual(headers.get('X-Yl-Elapsed-Us'), '2000300')
        self.assertEqual(headers['X-Yl-Timeline-State'], 'active')

    def test_get_range_head_and_actual_byte_log(self):
        self.start()
        self.assertEqual(self.request()[2], self.payload)
        status, headers, body = self.request(headers={'Range': 'bytes=10-19'})
        self.assertEqual((status, body, headers['Content-Range']),
                         (206, b'0123456789', 'bytes 10-19/300'))
        self.assertEqual(self.request(method='HEAD')[2], b'')
        records = self.records()
        self.assertEqual(headers['X-Yl-Request-Id'], str(records[1]['requestId']))
        self.assertEqual([r['bodyBytesWritten'] for r in records], [300, 10, 0])
        self.assertTrue(all(r['outcome'] == 'complete' for r in records))

    def test_proxy_trace_metadata_accepts_only_one_opaque_uuid(self):
        self.start()
        token = '87654321-1234-1234-1234-123456789abc'
        self.request(headers={'X-Yl-Trace-Id': token})
        self.request(headers={'X-Yl-Trace-Id': 'https://private?token=secret'})
        rows = self.records()
        self.assertEqual(rows[0]['proxyTraceID'], token)
        self.assertNotIn('proxyTraceID', rows[1])
        self.assertNotIn('secret', self.log.getvalue())

    def test_direct_hls_control_is_served_with_playlist_mime_type(self):
        body = b'#EXTM3U\n#EXT-X-ENDLIST\n'
        (self.root / 'direct.m3u8').write_bytes(body)
        with (self.root / 'SHA256SUMS').open('a') as inventory:
            inventory.write(hashlib.sha256(body).hexdigest() + '  ./direct.m3u8\n')
        self.start()
        status, headers, received = self.request('/direct.m3u8')
        self.assertEqual((status, received), (200, body))
        self.assertEqual(headers['Content-Type'], 'application/vnd.apple.mpegurl')

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

class ConnectionEvidenceTests(unittest.TestCase):
    def test_summary_requires_explicit_consistent_mode_and_sequence(self):
        self.assertTrue(hasattr(net,'summarize_connections'))
        rows=[dict(connectionMode='http11-keepalive',connectionId=1,connectionRequestIndex=n) for n in [1,2]]
        summary=net.summarize_connections(rows,'http11-keepalive')
        self.assertEqual(summary['reusedRequests'],1)
        for invalid in [[],[rows[0],rows[0]],list(reversed(rows)),[rows[1]],[dict(rows[0],connectionId=True)],
                        [dict(rows[0],connectionMode='close')],[{}]]:
            with self.subTest(rows=invalid),self.assertRaises(ValueError):net.summarize_connections(invalid,'http11-keepalive')
        with self.assertRaises(ValueError):net.summarize_connections([dict(r,connectionMode='http11-close') for r in rows],'http11-close')


if __name__ == '__main__':
    unittest.main()
