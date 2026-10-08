import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
from test_profiler_control import vm, flags


class TimelineControlTests(unittest.TestCase):
    def machine(self, *, ignore_set=False, recorder='Ring'):
        state={'streams':['Dart','Embedder','GC','Microtask'],'profiler':'true','mutations':[]}
        def rpc(method,params):
            if method=='getVM':return vm()
            if method=='getFlagList':return flags(state['profiler'])
            if method=='setFlag':
                state['profiler']=params['value'];return {'type':'Success'}
            if method=='getVMTimelineFlags':return dict(type='TimelineFlags',recorderName=recorder,
                availableStreams=['Dart','Embedder','GC','Microtask','Compiler'],recordedStreams=list(state['streams']))
            if method=='setVMTimelineFlags':
                state['mutations'].append(params)
                if not ignore_set:state['streams']=params['recordedStreams']
                return {'type':'Success'}
            raise AssertionError(method)
        return state,rpc

    def test_empty_stream_control_requires_actual_readback_and_profiler_off(self):
        from timeline_control import control_timeline
        state,rpc=self.machine()
        result=control_timeline(rpc,123,'off')
        self.assertEqual(result['after']['recordedStreams'],[])
        self.assertEqual(state['mutations'],[{'recordedStreams':[]}])
        self.assertFalse(result['profilerAfter']['after'])
        _,rpc=self.machine(ignore_set=True)
        with self.assertRaises(ValueError):control_timeline(rpc,123,'off')

    def test_observe_never_changes_streams_and_rejects_unusable_recorder_or_profiler(self):
        from timeline_control import control_timeline
        state,rpc=self.machine();state['profiler']='false';state['streams']=[]
        self.assertEqual(control_timeline(rpc,123,'observe')['after']['recordedStreams'],[])
        self.assertEqual(state['mutations'],[])
        for recorder in ('null','',None):
            _,rpc=self.machine(recorder=recorder)
            with self.assertRaises(ValueError):control_timeline(rpc,123,'on')
        _,rpc=self.machine()
        with self.assertRaises(ValueError):control_timeline(rpc,123,'observe')

    def test_timeline_mutation_is_opt_in_and_does_not_allow_arbitrary_vm_calls(self):
        from memory_mapping import http_rpc
        with tempfile.TemporaryDirectory() as tmp:
            journal=Path(tmp)/'rpc'
            plain=http_rpc('http://127.0.0.1:1/key=/',[],time.monotonic()+2,journal=journal)
            with self.assertRaises(ValueError):plain('setVMTimelineFlags',{'recordedStreams':[]})
            rpc=http_rpc('http://127.0.0.1:1/key=/',[],time.monotonic()+2,journal=journal,allow_timeline_control=True)
            for method,params in [('clearVMTimeline',{}),('setFlag',{'name':'profiler','value':'false'}),
                 ('setVMTimelineFlags',{'recordedStreams':['Compiler']}),('setVMTimelineFlags',{'recordedStreams':'[]'}),
                 ('setVMTimelineFlags',{'recordedStreams':[],'extra':1}),('getVMTimelineFlags',{'extra':1})]:
                with self.assertRaises(ValueError):rpc(method,params)
            self.assertFalse(journal.exists())

    def test_http_uses_vm_enum_list_encoding_and_keeps_raw_response(self):
        from http.server import BaseHTTPRequestHandler, HTTPServer
        import threading
        from urllib.parse import urlsplit, parse_qs
        from memory_mapping import http_rpc
        received=[]
        class Handler(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                received.append(parse_qs(urlsplit(self.path).query))
                body=b'{"result":{"type":"Success"}}'
                self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        server=HTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever);thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                records=[];journal=Path(tmp)/'rpc'
                rpc=http_rpc(f'http://127.0.0.1:{server.server_port}/key=/',records,time.monotonic()+3,journal=journal,allow_timeline_control=True)
                rpc('setVMTimelineFlags',{'recordedStreams':['Dart','Embedder','GC','Microtask']})
                rpc('setVMTimelineFlags',{'recordedStreams':[]})
                self.assertEqual(received,[{'recordedStreams':['[Dart,Embedder,GC,Microtask]']},{'recordedStreams':['[]']}])
                self.assertEqual(len(records),2);self.assertIn('body',journal.read_text())
        finally:server.shutdown();thread.join();server.server_close()

    def test_failed_pair_retains_eighteen_planned_observers_and_protocol(self):
        from run_timeline_comparison import collect_pair
        def fail(path,*args,**kwargs):path.mkdir();return False
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'new'
            with patch('run_allocation_stacks.collect',side_effect=fail):
                self.assertFalse(collect_pair(out,'unused'))
            result=json.loads((out/'comparison.json').read_text())
            self.assertEqual(len(result['arms']),2)
            for arm in result['arms']:
                self.assertEqual(len(arm['records']),9)
                self.assertTrue(all(r['status']=='not_observed' for r in arm['records']))
                self.assertEqual({r['tool'] for r in arm['records']},{'timeline-control','heap','vmmap'})
            self.assertFalse(result['complete'])
            self.assertEqual(json.loads((out/'protocol.json').read_text())['armOrder'],['on','off'])
            with self.assertRaises(FileExistsError):collect_pair(out,'unused')

    def test_resource_timeline_mode_rejects_mixed_observer_protocols(self):
        from run_resources import collect
        with tempfile.TemporaryDirectory() as tmp:
            for args in ({},dict(profile_cycles=True,lifetime_probes=True,allocation_stacks=True),dict(profile_cycles=True,lifetime_probes=True,endurance=True)):
                with self.assertRaises(ValueError):collect(Path(tmp)/'out','unused',timeline_control=True,**args)

if __name__=='__main__':unittest.main()
