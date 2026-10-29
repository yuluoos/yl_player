"""Bounded same-clock server durations; nested sleep is not additive to hold."""
from contextlib import contextmanager
import math

STAGES = ('latency', 'queue', 'hold', 'sleep', 'headerWrite', 'bodyWrite')


class RequestTiming:
    def __init__(self, now):
        self.now = now
        self.started = now()
        self.values = dict(version=1, valid=True, sleepRequestedSeconds=0.0)
        for stage in STAGES:
            self.values.update({stage+'Seconds':0.0, stage+'Calls':0, stage+'Failures':0})

    def add(self, field, value):
        current = self.values.get(field, 0.0)
        if not math.isfinite(value) or value < 0 or current is None:
            self.values['valid'] = False
            self.values[field] = None
        else:
            self.values[field] = current + value

    def requested_sleep(self, seconds):
        self.add('sleepRequestedSeconds', seconds)

    @contextmanager
    def measure(self, stage):
        if stage not in STAGES: raise ValueError('unknown timing stage')
        start = self.now()
        self.values[stage+'Calls'] += 1
        try:
            yield
        except BaseException:
            self.values[stage+'Failures'] += 1
            raise
        finally:
            self.add(stage+'Seconds', self.now()-start)

    def finish(self):
        seconds = self.now()-self.started
        valid = self.values['valid'] and math.isfinite(seconds) and seconds >= 0
        return dict(self.values, valid=valid, totalSeconds=seconds if valid else None)


def summarize_server_timing(rows):
    def require(ok):
        if not ok: raise ValueError('invalid server timing evidence')
    def finite(v):
        try: return type(v) in (int,float) and math.isfinite(v) and v >= 0
        except OverflowError: return False
    fields={'version','valid','totalSeconds','sleepRequestedSeconds'} | {s+k for s in STAGES for k in ('Seconds','Calls','Failures')}
    require(isinstance(rows,list) and 0 < len(rows) <= 10000)
    totals={k:0.0 for k in fields-{'version','valid'}}
    for row in rows:
        require(isinstance(row,dict));t=row.get('serverTiming')
        require(isinstance(t,dict) and set(t)==fields and type(t['version']) is int and t['version']==1 and t['valid'] is True)
        require(all(finite(t[k]) for k in totals))
        for s in STAGES:
            require(type(t[s+'Calls']) is int and type(t[s+'Failures']) is int and t[s+'Failures'] <= t[s+'Calls'] <= 1000000)
            require(t[s+'Calls'] > 0 or t[s+'Seconds']==0)
        require(row.get('method') in ('GET','HEAD') and row.get('outcome') in ('complete','disconnected','timeout','client_io_error'))
        size=row.get('bodyBytesWritten')
        require(type(size) is int and 0 <= size <= 64*1024*1024)
        require(row.get('timelineState') in ('active','pending'))
        require(t['latencyCalls']==int(row['timelineState']=='active') and t['headerWriteCalls'] <= 1)
        failures=sum(t[s+'Failures'] for s in STAGES if s!='sleep')
        require(failures <= 1 and t['sleepFailures'] <= t['holdFailures'])
        require(t['queueCalls']==t['holdCalls']+t['queueFailures'])
        require(t['holdCalls']==t['bodyWriteCalls']+t['holdFailures'])
        require(t['sleepCalls']==0 or t['holdCalls'] > 0)
        require(t['sleepCalls'] >= t['bodyWriteCalls']+t['sleepFailures'])
        require(t['queueCalls']==0 or (t['headerWriteCalls']==1 and t['headerWriteFailures']==0))
        require(t['latencyFailures']==0 or t['headerWriteCalls']==0)
        require((size+1023)//1024==t['bodyWriteCalls']-t['bodyWriteFailures'])
        if row['method']=='HEAD': require(t['queueCalls']==t['bodyWriteCalls']==size==0)
        if row['outcome']=='complete': require(t['headerWriteCalls']==1 and failures==0)
        require(t['sleepSeconds'] <= t['holdSeconds']+1e-6)
        require(sum(t[s+'Seconds'] for s in STAGES if s!='sleep') <= t['totalSeconds']+1e-6)
        require(t['sleepCalls'] > 0 or t['sleepRequestedSeconds']==0)
        for k in totals:
            value=totals[k]+t[k];require(finite(value));totals[k]=value
    return dict(version=1, complete=True, requests=len(rows), sums=totals,
        interpretation='Same-server monotonic durations. Sleep is nested in hold; concurrent request totals are not wall time. Writes do not prove client receipt or display.',
        capabilityAccepted=False)
