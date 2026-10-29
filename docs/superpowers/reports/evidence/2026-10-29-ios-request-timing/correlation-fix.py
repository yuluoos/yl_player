from pathlib import Path
p=Path('tool/playback_network/network_profile.py');s=p.read_text();mark='        with self.server.records_lock:\n            self.server.next_record_id += 1';s=s.replace(mark,'''        trace_ids = self.headers.get_all('X-Yl-Trace-Id', [])
        if len(trace_ids) == 1 and re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', trace_ids[0]):
            row['proxyTraceID'] = trace_ids[0]
'''+mark,1);p.write_text(s)
p=Path('tool/playback_network/proxy_boundaries.py');s=p.read_text();s=s.replace("    optional = times | {'httpStatus', 'serverRequestID'}", "    optional = times | {'httpStatus', 'serverRequestID', 'correlationID'}\n    uuid_pattern = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'\n    def uuid(value):\n        return isinstance(value, str) and re.fullmatch(uuid_pattern, value)")
s=s.replace('    servers = {}','    servers = {}; trace_ids = {}',1)
s=s.replace('        servers[ident] = server','''        servers[ident] = server
        if 'proxyTraceID' in server:
            token = server['proxyTraceID']; require(uuid(token))
            require(token.lower() not in trace_ids)
            trace_ids[token.lower()] = ident''',1)
s=s.replace("if key != 'proxyID'", "if key not in ('proxyID', 'correlationID')",1)
s=s.replace("('lastBody','upstreamComplete'),('firstSend','lastSend'),('lastSend','lastSendComplete')", "('lastBody','upstreamComplete'),('firstSend','lastSend')",1)
s=s.replace("        require(row['sendWaitMax'] <= row['sendWaitSum'] + 1e-9)","""        if row['sendCount'] == row['sendCompletions'] and 'lastSend' in row and 'lastSendComplete' in row:
            require(row['lastSend'] <= row['lastSendComplete'])
        require(row['sendWaitMax'] <= row['sendWaitSum'] + 1e-9)""",1)
s=s.replace("        server_id = row.get('serverRequestID'); server = None", """        server_id = row.get('serverRequestID'); server = None
        token = row.get('correlationID')
        if token is not None:
            require(uuid(token))
            linked = trace_ids.get(token.lower())
            if linked is not None:
                require(server_id is None or server_id == linked)
                server_id = linked""",1)
s=s.replace("            require(integer(row.get('httpStatus')) and row['httpStatus'] == server.get('status'))", """            if 'response' in row or 'httpStatus' in row:
                require(integer(row.get('httpStatus')) and row['httpStatus'] == server.get('status'))
            if token is not None and 'proxyTraceID' in server:
                require(token.lower() == server['proxyTraceID'].lower())""",1)
s+='''

def record_proxy_observation(receipt, rows, server_rows):
    observation = summarize_proxy_boundaries(rows, server_rows)
    receipt['proxyRequestObservation'] = observation
    if not observation['fullyCorrelated']:
        receipt['errors'].append('proxy request correlation incomplete')
''';p.write_text(s)
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text().replace('from proxy_boundaries import proxy_trace_version, summarize_proxy_boundaries','from proxy_boundaries import proxy_trace_version, record_proxy_observation',1).replace("            receipt['proxyRequestObservation'] = summarize_proxy_boundaries(\n                read_rows", "            record_proxy_observation(receipt,\n                read_rows",1);p.write_text(s)
p=Path('tool/playback_network/test_network_profile.py');s=p.read_text();mark='    def test_direct_hls_control_is_served_with_playlist_mime_type(self):';s=s.replace(mark,'''    def test_proxy_trace_metadata_accepts_only_one_opaque_uuid(self):
        self.start()
        token = '87654321-1234-1234-1234-123456789abc'
        self.request(headers={'X-Yl-Trace-Id': token})
        self.request(headers={'X-Yl-Trace-Id': 'https://private?token=secret'})
        rows = self.records()
        self.assertEqual(rows[0]['proxyTraceID'], token)
        self.assertNotIn('proxyTraceID', rows[1])
        self.assertNotIn('secret', self.log.getvalue())

'''+mark);p.write_text(s)
