import http.client
from http.server import HTTPServer,BaseHTTPRequestHandler
import threading
import abr_accesslog
import json
import unittest
import network_profile as net
from test_network_profile import Clock, profile, step
try:
    import triggered_fault as fault
except ImportError:
    fault = None


def evidence():
    return dict(version=1, elapsed=42.0, generation=1, position=39.0,
                installedElapsed=37.0, attempts=2, firstHighElapsed=40.0,
                lastHighElapsed=42.0, highFrames=48)


class TriggeredFaultTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(fault, 'triggered fixture is not implemented')
        self.clock=Clock()
        self.base=net.Profile(profile(step(rate=1000)))
        self.shaper=fault.TriggeredShaper(self.base,rate=100,duration=5,now=self.clock.now,sleep=self.clock.sleep)

    def test_fault_changes_inflight_budget_only_after_one_valid_trigger(self):
        self.clock.value=42
        self.assertEqual(self.shaper.state(100)[1]['bytesPerSecond'],1000)
        ack=self.shaper.trigger(evidence())
        self.assertEqual(ack['startSeconds'],42)
        self.assertEqual(ack['endSeconds'],47)
        self.assertEqual(self.shaper.state(100)[1]['bytesPerSecond'],100)
        self.shaper.consume(1000,100)
        self.assertAlmostEqual(self.clock.value,47.5)
        with self.assertRaises(ValueError):self.shaper.trigger(evidence())
        self.assertEqual(self.base.steps,[step(rate=1000)])

    def test_bad_or_late_evidence_never_arms_fault(self):
        for patch in [dict(position=71),dict(attempts=3),dict(generation=0),dict(highFrames=1),
                      dict(firstHighElapsed=41),dict(installedElapsed=41),dict(elapsed=float('nan'))]:
            with self.subTest(patch=patch),self.assertRaises(ValueError):self.shaper.trigger(dict(evidence(),**patch))
        self.assertIsNone(self.shaper.snapshot()['trigger'])

    def test_control_rejects_wrong_identity_and_replay_and_returns_ack(self):
        control=fault.ControlServer(self.shaper,'127.0.0.1','a'*32)
        self.addCleanup(control.close)
        for path,status in [('/fault/'+'b'*32,403),('/fault/'+'a'*32,200),('/fault/'+'a'*32,409)]:
            c=http.client.HTTPConnection('127.0.0.1',control.port,timeout=2)
            c.request('POST',path,json.dumps(evidence()),{'Content-Type':'application/json'})
            response=c.getresponse();body=response.read();c.close()
            self.assertEqual(response.status,status)
            if status==200:self.assertEqual(json.loads(body)['evidence'],evidence())
        self.assertEqual(len(control.records),3)

    def test_frame_binding_rejects_forged_trigger_or_missing_ack(self):
        e=evidence();self.clock.value=42;ack=self.shaper.trigger(e)
        frames=[dict(elapsed=40+i*2/47,generation=1,frames=1,width=640,position=37+i*2/47,
                     rate=1,itemStatus=1,resumeSeekPending=False) for i in range(48)]
        high_only=list(frames)
        frames.extend(dict(elapsed=t,generation=1,frames=1,width=320,position=t-3,rate=1,itemStatus=1,resumeSeekPending=False) for t in (43,44))
        rows=[dict(automaticEvents=[dict(outcome='installed',attempt=2,elapsedAfter=37)])]
        client=dict(evidence=e,status=200,response=ack)
        result=fault.summarize_trigger(self.shaper.snapshot(),client,rows,frames)
        self.assertTrue(result['bound']);self.assertFalse(result['capabilityAccepted'])
        with self.assertRaises(ValueError):fault.summarize_trigger(self.shaper.snapshot(),client,rows,high_only)
        for bad in [dict(client,status=0),dict(client,evidence=dict(e,highFrames=49))]:
            with self.assertRaises(ValueError):fault.summarize_trigger(self.shaper.snapshot(),bad,rows,frames)
        paused=dict(frames[20],frames=0,rate=0)
        with self.assertRaises(ValueError):fault.summarize_trigger(self.shaper.snapshot(),client,rows,frames[:20]+[paused]+frames[20:])
        frames[20]['width']=320
        with self.assertRaises(ValueError):fault.summarize_trigger(self.shaper.snapshot(),client,rows,frames)

    def test_unstarted_fixture_cleanup_does_not_wait_for_a_missing_serve_loop(self):
        close=getattr(abr_accesslog,'close_fixture',None)
        self.assertIsNotNone(close,'cleanup must distinguish unstarted listener')
        server=HTTPServer(('127.0.0.1',0),BaseHTTPRequestHandler)
        done=threading.Event();failures=[]
        def cleanup():
            try:close(server,None)
            except Exception as error:failures.append(error)
            finally:done.set()
        worker=threading.Thread(target=cleanup,daemon=True);worker.start()
        completed=done.wait(.3)
        if not completed:
            # Release the intentionally detected old shutdown wait before failing.
            release=threading.Thread(target=server.serve_forever,daemon=True);release.start()
            worker.join(1);release.join(1)
        server.server_close()
        self.assertTrue(completed,'unstarted shutdown blocked')
        self.assertEqual(failures,[])
