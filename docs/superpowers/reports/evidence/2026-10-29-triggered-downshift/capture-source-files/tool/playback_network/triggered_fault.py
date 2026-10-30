"""Owned test-only fault overlay. Static profile and event clock stay separate."""
import copy
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import math
import threading
from network_profile import Shaper, integer, owned_bind_host, interrupt_socket


def validate_evidence(e):
    fields={'version','elapsed','generation','position','installedElapsed','attempts',
            'firstHighElapsed','lastHighElapsed','highFrames'}
    if not isinstance(e,dict) or set(e)!=fields:raise ValueError('invalid trigger evidence')
    if not all(type(v) in (int,float) and math.isfinite(v) and 0<=v<=100000 for v in e.values()):
        raise ValueError('invalid trigger numbers')
    if not (type(e['version']) is int and e['version']==1 and type(e['generation']) is int and e['generation']>=1 and
            type(e['attempts']) is int and 1<=e['attempts']<=2 and type(e['highFrames']) is int and e['highFrames']>=48 and
            e['installedElapsed']<e['firstHighElapsed']<=e['lastHighElapsed']==e['elapsed'] and
            e['lastHighElapsed']-e['firstHighElapsed']>=2 and e['position']<=70):
        raise ValueError('high baseline not established')


class TriggeredShaper(Shaper):
    def __init__(self, profile, *, rate, duration, **kwargs):
        if not integer(rate,1000000) or type(duration) not in (int,float) or not math.isfinite(duration) or not 0<duration<=10:
            raise ValueError('invalid bounded fault')
        super().__init__(profile,**kwargs)
        self.rate,self.duration=rate,duration
        self.trigger_lock=threading.Lock()
        self.trigger_record=None

    def trigger(self,evidence):
        validate_evidence(evidence)
        with self.trigger_lock:
            if self.trigger_record is not None:raise ValueError('fault already triggered')
            start=self.elapsed()
            self.trigger_record=dict(version=1,startSeconds=start,endSeconds=start+self.duration,
                                     rate=self.rate,evidence=copy.deepcopy(evidence))
            return copy.deepcopy(self.trigger_record)

    def snapshot(self):
        with self.trigger_lock:
            return dict(version=1,baseProfileSha256=self.profile.sha256,rate=self.rate,duration=self.duration,
                        trigger=copy.deepcopy(self.trigger_record),capabilityAccepted=False)

    def state(self,deadline):
        elapsed,step,boundary=super().state(deadline)
        with self.trigger_lock:
            trigger=self.trigger_record
        if trigger and trigger['startSeconds']<=elapsed<trigger['endSeconds']:
            return elapsed,dict(step,bytesPerSecond=self.rate),min(boundary,trigger['endSeconds'])
        return elapsed,step,boundary


class ControlServer:
    """A separate bounded control listener never occupies a media handler."""
    def __init__(self,shaper,host,token):
        import re
        if not isinstance(token,str) or not re.fullmatch('[a-f0-9]{32}',token):raise ValueError('invalid control token')
        self.records=[]
        owner=self
        class Handler(BaseHTTPRequestHandler):
            def setup(self):
                self.request.settimeout(1)
                super().setup()
                self.deadline=threading.Timer(2,interrupt_socket,args=(self.request,));self.deadline.daemon=True;self.deadline.start()
            def finish(self):
                self.deadline.cancel()
                super().finish()
            def log_message(self,*args):pass
            def do_POST(self):
                status=403;ack={}
                if len(owner.records)>=16:
                    self.send_error(429);return
                lengths=self.headers.get_all('Content-Length',[])
                if self.path=='/fault/'+token and len(lengths)==1 and lengths[0].isdigit() and 0<int(lengths[0])<=2048 and not self.headers.get_all('Transfer-Encoding'):
                    try:
                        data=self.rfile.read(int(lengths[0]))
                        if len(data)!=int(lengths[0]):raise ValueError('short body')
                        ack=shaper.trigger(json.loads(data));status=200
                    except (ValueError,TypeError,OverflowError):status=409
                    except OSError:status=408
                owner.records.append(dict(serverSeconds=shaper.elapsed(),status=status))
                body=json.dumps(ack,allow_nan=False).encode()
                try:
                    self.send_response(status);self.send_header('Content-Length',str(len(body)))
                    self.send_header('Connection','close');self.end_headers();self.wfile.write(body)
                except OSError:pass
        self.server=HTTPServer((owned_bind_host(None if host=='127.0.0.1' else host),0),Handler)
        self.port=self.server.server_port
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()

    def close(self):
        self.server.shutdown();self.server.server_close();self.thread.join(timeout=2)


def summarize_trigger(trace,client,rows,frames):
    def require(v):
        if not v:raise ValueError('unbound triggered fault evidence')
    require(isinstance(trace,dict) and trace.get('version')==1 and isinstance(client,dict))
    ack=trace.get('trigger');require(isinstance(ack,dict));e=ack.get('evidence');validate_evidence(e)
    require(client.get('status')==200 and client.get('evidence')==e and client.get('response')==ack)
    require(ack['rate']==trace['rate'] and abs(ack['endSeconds']-ack['startSeconds']-trace['duration'])<1e-9)
    require(any(v.get('outcome')=='installed' and v.get('attempt')==e['attempts'] and
                v.get('elapsedAfter')==e['installedElapsed'] for v in rows[-1]['automaticEvents']))
    window=[f for f in frames if e['firstHighElapsed']<=f['elapsed']<=e['lastHighElapsed']]
    require(all(f['generation']==e['generation'] and f['rate']>0 and f['itemStatus']==1 and not f['resumeSeekPending'] for f in window))
    selected=[f for f in window if f['frames']>0]
    require(len(selected)>=2 and selected[0]['elapsed']==e['firstHighElapsed'] and selected[-1]['elapsed']==e['lastHighElapsed'])
    require(sum(f['frames'] for f in selected)==e['highFrames'] and all(f['width']==640 and f['generation']==e['generation'] and
            f['rate']>0 and f['itemStatus']==1 and not f['resumeSeekPending'] for f in selected))
    require(all(0<b['elapsed']-a['elapsed']<=.5 and b['position']>a['position'] for a,b in zip(selected,selected[1:])))
    require(selected[-1]['position']==e['position'])
    return dict(bound=True,trigger=ack,capabilityAccepted=False,interpretation='A bound high baseline starts the fault; second downshift, exhausted windows and recovery still require the unchanged strict media validators.')
