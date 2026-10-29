from pathlib import Path
p=Path('tool/playback_network/network_profile.py');s=p.read_text();s=s.replace('        self.connection_ids = {}','''        self.connection_ids = {}
        self.lifecycle_origin = now()
        self.lifecycle_connections = {}
        self.lifecycle_rejections = []''');s=s.replace('''                self.rejected_requests += 1
                self.shutdown_request(request)''','''                self.rejected_requests += 1
                if len(self.lifecycle_rejections) < 32:
                    self.lifecycle_rejections.append(dict(elapsed=self.shaper.now()-self.lifecycle_origin,
                        reason='activeLimit' if self.active >= 8 else 'connectionLimit', active=self.active))
                self.shutdown_request(request)''');s=s.replace('''            self.connection_ids[request] = self.requests
            self.active_sockets.add(request)''','''            self.connection_ids[request] = self.requests
            self.lifecycle_connections[self.requests] = dict(connectionId=self.requests,
                acceptedSeconds=self.shaper.now()-self.lifecycle_origin, closedSeconds=None,
                activeAtAdmission=self.active, requestIds=[], closeReason=None)
            self.active_sockets.add(request)''');s=s.replace('''                self.active -= 1
                self.active_sockets.discard(request)''','''                row = self.lifecycle_connections[self.connection_ids[request]]
                row['closedSeconds'] = self.shaper.now()-self.lifecycle_origin
                if row['closeReason'] is None: row['closeReason'] = 'handlerEnded'
                self.active -= 1
                self.active_sockets.discard(request)''');s=s.replace('''    def wait_handlers(self):''','''    def interrupt_connection(self, connection, reason):
        with self.handlers:
            self._mark_close(connection, reason)
        interrupt_socket(connection)

    def _mark_close(self, connection, reason):
        row = self.lifecycle_connections.get(self.connection_ids.get(connection))
        if row is not None and row['closedSeconds'] is None and row['closeReason'] is None:
            row['closeReason'] = reason

    def connection_lifecycle(self):
        # Snapshot after server_close for complete evidence; no addresses/headers.
        import copy
        with self.handlers:
            return copy.deepcopy(dict(version=1, acceptedCount=self.requests,
                rejectedCount=self.rejected_requests,
                droppedRejections=self.rejected_requests-len(self.lifecycle_rejections),
                connections=list(self.lifecycle_connections.values()), rejections=self.lifecycle_rejections))

    def wait_handlers(self):''');s=s.replace('''            for connection in self.active_sockets:
                interrupt_socket(connection)''','''            for connection in self.active_sockets:
                self._mark_close(connection, 'serverShutdown')
                interrupt_socket(connection)''');s=s.replace('''        # Never print incoming URLs/headers or exception text.
        pass''','''        # Never print incoming URLs/headers or exception text.
        with self.handlers:
            self._mark_close(request, 'handlerError')''');s=s.replace('''self.server.connection_timeout, interrupt_socket, args=(self.request,))''','''self.server.connection_timeout, self.server.interrupt_connection,
            args=(self.request, 'absoluteDeadline'))''');s=s.replace('''        self.connection_request_index += 1
        s = self.server.shaper''','''        self.connection_request_index += 1
        with self.server.handlers:
            self.server.lifecycle_connections[self.connection_id]['requestIds'].append(request_id)
        s = self.server.shaper''');p.write_text(s)
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text();needle='''        if server:
            try:
                from network_profile import summarize_connections''';replace='''        if server:
            try:
                from connection_lifecycle import summarize_lifecycle
                lifecycle = server.connection_lifecycle()
                (out/'connection-lifecycle.json').write_text(json.dumps(lifecycle,indent=2)+'\\n')
                receipt['connectionLifecycleObservation'] = summarize_lifecycle(lifecycle,read_rows(out/'requests.jsonl'))
                if not receipt['connectionLifecycleObservation']['complete']:
                    receipt['errors'].append('connection lifecycle evidence incomplete')
            except (OSError,ValueError,KeyError,TypeError):
                receipt['errors'].append('connection lifecycle evidence invalid')
            try:
                from network_profile import summarize_connections''';assert needle in s;s=s.replace(needle,replace);p.write_text(s)
