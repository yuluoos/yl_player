from pathlib import Path
p=Path('tool/playback_network/test_network_profile.py');s=p.read_text();at=s.index('    def test_active_clock_header')
s=s[:at]+'''    def test_http11_persistence_reuses_socket_and_preserves_range_head(self):
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

'''+s[at:];p.write_text(s)
