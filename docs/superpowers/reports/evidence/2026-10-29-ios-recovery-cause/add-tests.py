from pathlib import Path
p=Path('tool/playback_network/test_network_profile.py');s=p.read_text();anchor='    def test_actual_server_records_oversleep_without_increasing_rate_credit(self):'
new='''    def lifecycle(self):
        self.assertTrue(callable(getattr(self.server, 'connection_lifecycle', None)),
                        'Pre-request connection closures need preserved evidence')
        return self.server.connection_lifecycle()

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

    def test_lifecycle_distinguishes_deadline_from_unobserved_peer_close(self):
        self.start();self.server.connection_timeout=.05
        conn=socket.create_connection(('127.0.0.1',self.server.server_port),timeout=2)
        try:self.assertEqual(conn.recv(1),b'')
        finally:conn.close()
        self.assertTrue(self.server.wait_handlers());trace=self.lifecycle()
        self.assertEqual(trace['connections'][0]['closeReason'],'absoluteDeadline')
        self.assertEqual(trace['connections'][0]['requestIds'],[])
        self.assertGreaterEqual(trace['connections'][0]['closedSeconds'],trace['connections'][0]['acceptedSeconds'])

'''
assert anchor in s;s=s.replace(anchor,new+anchor);p.write_text(s)
