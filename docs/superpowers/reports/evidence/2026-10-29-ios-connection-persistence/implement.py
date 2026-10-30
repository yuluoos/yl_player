from pathlib import Path
p=Path('tool/playback_network/network_profile.py');s=p.read_text().replace('def __init__(self, root, profile, log, port, now, sleep, start_on_first_get, run_id, owned_host=None):','def __init__(self, root, profile, log, port, now, sleep, start_on_first_get, run_id, owned_host=None, connection_mode="close"):')
s=s.replace('        host = owned_bind_host(owned_host)','        if connection_mode not in ("close", "http11-close", "http11-keepalive"):\n            raise ValueError("invalid connection mode")\n        self.connection_mode = connection_mode\n        self.connection_ids = {}\n        host = owned_bind_host(owned_host)',1)
s=s.replace('            self.requests += 1\n            self.active_sockets.add(request)','            self.requests += 1\n            self.connection_ids[request] = self.requests\n            self.active_sockets.add(request)')
s=s.replace('                self.active_sockets.discard(request)','                self.active_sockets.discard(request)\n                self.connection_ids.pop(request, None)')
s=s.replace('    def setup(self):\n        self.request.settimeout(2)','    def setup(self):\n        self.protocol_version = "HTTP/1.0" if self.server.connection_mode == "close" else "HTTP/1.1"\n        self.connection_id = self.server.connection_ids[self.request]\n        self.connection_request_index = 0\n        self.request.settimeout(2)')
s=s.replace('    def serve(self, head):\n        s = self.server.shaper','''    def serve(self, head):
        # A persistent socket must not bypass the existing 10,000-record budget.
        with self.server.records_lock:
            if self.server.next_record_id >= 10000:
                self.close_connection = True
                return
            self.server.next_record_id += 1
            request_id = self.server.next_record_id
        self.connection_request_index += 1
        s = self.server.shaper''')
s=s.replace('row = dict(schemaVersion=1, profile=s.profile.id,','row = dict(schemaVersion=1, profile=s.profile.id,\n                   connectionMode=self.server.connection_mode, connectionId=self.connection_id,\n                   connectionRequestIndex=self.connection_request_index, requestId=request_id,')
s=s.replace("        with self.server.records_lock:\n            self.server.next_record_id += 1\n            row['requestId'] = self.server.next_record_id\n",'')
s=s.replace("            self.send_header('Connection', 'close')","            persistent = self.server.connection_mode == 'http11-keepalive' and not self.close_connection\n            self.send_header('Connection', 'keep-alive' if persistent else 'close')")
s=s.replace("            self.close_connection = True\n\n\ndef make_server", "            if self.server.connection_mode != 'http11-keepalive' or row['outcome'] != 'complete':\n                self.close_connection = True\n\n\ndef make_server")
s=s.replace('start_on_first_get=False, run_id=None, owned_host=None):\n    return FixtureServer(root, profile, log, port, now, sleep, start_on_first_get, run_id, owned_host)','start_on_first_get=False, run_id=None, owned_host=None, connection_mode="close"):\n    return FixtureServer(root, profile, log, port, now, sleep, start_on_first_get, run_id, owned_host, connection_mode)')
s=s.replace("    parser.add_argument('--start-on-first-get', action='store_true')","    parser.add_argument('--connection-mode', choices=('close','http11-close','http11-keepalive'), default='close')\n    parser.add_argument('--start-on-first-get', action='store_true')")
# Standalone server forwards its explicit mode too.
s=s.replace('owned_host=args.owned_host)', 'owned_host=args.owned_host, connection_mode=args.connection_mode)')
p.write_text(s)
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text().replace("        receipt['autoScenario'] = auto_scenario", "        receipt['connectionMode'] = getattr(args, 'connection_mode', 'close')\n        if receipt['connectionMode'] not in ('close','http11-close','http11-keepalive'):\n            raise ValueError('invalid connection mode')\n        receipt['autoScenario'] = auto_scenario")
s=s.replace('owned_host=host if physical_device else None)', "owned_host=host if physical_device else None, connection_mode=receipt['connectionMode'])")
s=s.replace("    p.add_argument('--profiles',", "    p.add_argument('--connection-mode',choices=('close','http11-close','http11-keepalive'),default='close')\n    p.add_argument('--profiles',")
p.write_text(s)
