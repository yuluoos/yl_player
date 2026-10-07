import unittest
import memory_mapping as mapping
from test_memory_categories import HEADER, END


def vm():return dict(type='VM',pid=123,isolates=[dict(id='isolates/1')],isolateGroups=[dict(id='isolateGroups/1')])
def memory():return dict(type='MemoryUsage',heapUsage=100,heapCapacity=200,externalUsage=12)

class MappingTests(unittest.TestCase):
    def test_system_groups_are_opt_in_distinct_and_identity_checked(self):
        v=dict(vm(),systemIsolateGroups=[dict(id='isolateGroups/system')])
        calls=[]
        def rpc(method,params):
            calls.append((method,params))
            return v if method=='getVM' else memory()
        r=mapping.read_memory(rpc,123,include_system=True)
        self.assertEqual(r['scope'],'application-and-system-isolate-groups')
        self.assertEqual([(g['id'],g['kind']) for g in r['groups']],
                         [('isolateGroups/1','application'),('isolateGroups/system','system')])
        self.assertEqual(len(calls),4)
        for bad in (vm(),dict(v,systemIsolateGroups=[dict(id='isolateGroups/1')]),
                    dict(v,systemIsolateGroups=[None])):
            with self.assertRaises(ValueError):mapping.read_memory(lambda m,p:bad,123,include_system=True)
        seq=iter([v,memory(),memory(),dict(v,systemIsolateGroups=[])])
        with self.assertRaises(ValueError):mapping.read_memory(lambda m,p:next(seq),123,include_system=True)
        empty=dict(vm(),systemIsolateGroups=[])
        self.assertEqual(len(mapping.read_memory(lambda m,p:empty if m=='getVM' else memory(),123,include_system=True)['groups']),1)

    def test_only_literal_loopback_service_without_redirect_targets(self):
        self.assertEqual(mapping.service_uri('Connecting to Flutter application at http://127.0.0.1:1234/key=/'), 'http://127.0.0.1:1234/key=/')
        for uri in ('http://example.com:12/k/','http://127.0.0.1:12@evil/k/','http://127.0.0.1:12/k/?next=http://evil','https://127.0.0.1/k/'):
            with self.assertRaises(ValueError):mapping.service_uri('Connecting to Flutter application at '+uri)

    def test_vm_memory_is_identity_checked_without_forced_gc(self):
        calls=[]
        def rpc(method,params):
            calls.append((method,params));return vm() if method=='getVM' else memory()
        r=mapping.read_memory(rpc,123)
        self.assertEqual(r['groups'][0]['memory'],memory())
        self.assertEqual([m for m,p in calls],['getVM','getIsolateGroupMemoryUsage','getVM'])
        self.assertEqual(r['scope'],'non-system-isolate-groups')
        with self.assertRaises(ValueError):mapping.read_memory(rpc,999)

    def test_unavailable_negative_boolean_or_changed_group_is_not_zero(self):
        for bad in ({'type':'Sentinel'},dict(memory(),heapUsage=-1),dict(memory(),heapUsage=True),dict(memory(),heapUsage=201)):
            with self.assertRaises(ValueError):mapping.read_memory(lambda m,p:vm() if m=='getVM' else bad,123)
        calls=iter([vm(),memory(),dict(vm(),isolateGroups=[])])
        with self.assertRaises(ValueError):mapping.read_memory(lambda m,p:next(calls),123)

    def test_exact_addresses_keep_rounded_usage_separate(self):
        text=HEADER+'Untagged 512K 96K 96K 0K 0K 0K 0K 1\n'+END+'\nUntagged 104580000-104600000 [ 512K 96K 96K 0K] r--/rwx SM=PRV  \n'
        r=mapping.untagged_regions(text,123)
        self.assertEqual(r[0]['virtualBytes'],524288)
        self.assertEqual(r[0]['dirtySize'],'96K')
        self.assertEqual(r[0]['start'],'0x104580000')
        for bad in (text.replace('104600000','104500000'),text.replace('[ 512K 96K','[ unknown 96K'),text+text.splitlines()[-1]+'\n'):
            with self.assertRaises(ValueError):mapping.untagged_regions(bad,123)

    def test_reserved_category_is_not_an_allocated_untagged_region(self):
        text=HEADER+'Untagged 512K 96K 96K 0K 0K 0K 0K 1\nUntagged (reserved) 32K 0K 0K 0K 0K 0K 0K 1         reserved VM address space (unallocated)\n'+END
        text+='Untagged 104580000-104600000 [ 512K 96K 96K 0K] r--/rwx SM=PRV  \n'
        text+='Untagged (reserved) 115d00000-115d08000 [ 32K 0K 0K 0K] rw-/rwx SM=NUL          reserved VM address space (unallocated)\n'
        rows=mapping.untagged_regions(text,123)
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['start'],'0x104580000')


class RpcRetentionTests(unittest.TestCase):
    def test_hard_kill_retains_completed_response_and_inflight_request(self):
        import json, subprocess, sys, tempfile, threading, time
        from http.server import BaseHTTPRequestHandler, HTTPServer
        from pathlib import Path
        stop=threading.Event();inflight=threading.Event()
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                if self.path.endswith('/getVM'):
                    body=json.dumps({'result':vm()}).encode()
                    self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
                else:inflight.set();stop.wait(4)
        server=HTTPServer(('127.0.0.1',0),Handler)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                path=Path(tmp);log=path/'log';journal=path/'log.rpc.jsonl'
                log.write_text(f'Connecting to Flutter application at http://127.0.0.1:{server.server_port}/key=/')
                process=subprocess.Popen([sys.executable,str(Path(mapping.__file__)),str(log),'123'],stdout=subprocess.PIPE)
                try:
                    self.assertTrue(inflight.wait(3),'Did not reach the request after completed getVM')
                    process.kill();process.communicate(timeout=2)
                    self.assertTrue(journal.exists(),'Completed RPC evidence vanished on hard kill')
                    records=[json.loads(l) for l in journal.read_text().splitlines()]
                    self.assertTrue(any(x['stage']=='body' and x['method']=='getVM' for x in records))
                    self.assertTrue(any(x['stage']=='request' and x['method']=='getIsolateGroupMemoryUsage' for x in records))
                finally:
                    if process.poll() is None:process.kill();process.communicate(timeout=2)
        finally:stop.set();server.shutdown();server.server_close();thread.join(2)

    def test_malformed_and_oversized_responses_keep_bounded_raw_evidence(self):
        import base64, json, subprocess, sys, tempfile, threading
        from http.server import BaseHTTPRequestHandler, HTTPServer
        from pathlib import Path
        for body in (b'not-json',b'x'*(1048576+5)):
            class Handler(BaseHTTPRequestHandler):
                def log_message(self,*args):pass
                def do_GET(self):
                    self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers()
                    try:self.wfile.write(body)
                    except (BrokenPipeError,ConnectionResetError):pass
            server=HTTPServer(('127.0.0.1',0),Handler)
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                with tempfile.TemporaryDirectory() as tmp:
                    path=Path(tmp);log=path/'log';journal=path/'log.rpc.jsonl'
                    log.write_text(f'Connecting to Flutter application at http://127.0.0.1:{server.server_port}/key=/')
                    result=subprocess.run([sys.executable,str(Path(mapping.__file__)),str(log),'123'],capture_output=True,timeout=4)
                    self.assertNotEqual(result.returncode,0)
                    self.assertTrue(journal.exists(),'Malformed/oversized response evidence lost')
                    events=[json.loads(l) for l in journal.read_text().splitlines()]
                    self.assertTrue(any(e['stage']=='headers' and e['httpStatus']==200 for e in events))
                    captured=b''.join(base64.b64decode(e['data']) for e in events if e['stage']=='body')
                    self.assertEqual(captured,body[:1048576])
            finally:server.shutdown();server.server_close();thread.join(2)

if __name__=='__main__':unittest.main()
