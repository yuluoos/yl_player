"""Diagnostic only: enable Instruments before playback; preserve gate and trace receipts."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import select
import shutil
import signal
import struct
import subprocess
import sys
import time
import uuid


class RowTail:
    def __init__(self,path):
        self.path=path; self.offset=0; self.pending=b''; self.latest=None
    def poll(self):
        if not self.path.exists(): return self.latest
        with self.path.open('rb') as f:
            f.seek(self.offset); data=f.read(); self.offset=f.tell()
        lines=(self.pending+data).split(b'\n');self.pending=lines.pop()
        if len(self.pending)>1024*1024: raise ValueError('unterminated diagnostic row exceeds 1 MiB')
        for line in lines:
            if line: self.latest=json.loads(line)
        return self.latest


def check_recorder(code, *, now, started, settled, stop_sent, duration):
    # A successful recorder exit before playback still means no coverage.
    if not settled and (code is not None or (started is not None and now-started >= duration-2)):
        raise RuntimeError('recorder unavailable or time limit imminent before playback settled')
    if code is not None and (code != 0 or not (stop_sent or (started is not None and now-started >= duration-2))):
        raise RuntimeError(f'recorder exited unexpectedly during playback: {code}')


class StartedNotification:
    """Darwin descriptor delivery, not notify_check's possible false positives."""
    def __init__(self, name):
        self.name=name
        self.lib=ctypes.CDLL('/usr/lib/libSystem.B.dylib')
        self.lib.notify_register_file_descriptor.argtypes=[ctypes.c_char_p,ctypes.POINTER(ctypes.c_int),ctypes.c_int,ctypes.POINTER(ctypes.c_int)]
        self.lib.notify_register_file_descriptor.restype=ctypes.c_uint32
        self.lib.notify_cancel.argtypes=[ctypes.c_int]
        self.fd=ctypes.c_int(-1); self.token=ctypes.c_int(-1)
        status=self.lib.notify_register_file_descriptor(name.encode(),ctypes.byref(self.fd),0,ctypes.byref(self.token))
        if status: raise RuntimeError(f'notification registration failed: {status}')
        self.closed=False

    def received(self):
        if not select.select([self.fd.value],[],[],0)[0]: return False
        data=os.read(self.fd.value,4)
        if len(data)!=4 or struct.unpack('!I',data)[0]!=self.token.value:
            raise RuntimeError('unexpected Darwin notification token')
        return True

    def close(self):
        if not self.closed:
            self.lib.notify_cancel(self.token.value)  # also closes its owned fd
            self.closed=True


def revoke_gate(bench, token, errors):
    try:
        tmp=bench/'trace-aborted.tmp';tmp.write_text(json.dumps(dict(token=token,errors=errors)))
        tmp.replace(bench/'trace-aborted.json')
    except OSError as error:
        errors.append('cannot write gate revocation: '+repr(error))
    try: (bench/'trace-started.json').unlink(missing_ok=True)
    except OSError as error: errors.append('cannot remove gate receipt: '+repr(error))


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--products',type=Path,required=True)
    p.add_argument('--directory',type=Path,required=True)
    p.add_argument('--long',action='store_true')
    p.add_argument('--app-name',default='yl_player_example.app')
    args=p.parse_args()
    root=Path(__file__).resolve().parents[2]; out=args.directory.resolve()
    out.mkdir(parents=True,exist_ok=False)
    if shutil.disk_usage(out).free<10*1024**3: raise RuntimeError('Require 10 GiB free for bounded diagnostic capture')
    token=uuid.uuid4().hex; name='dev.ylplayer.trace.'+token
    note=StartedNotification(name)
    bench=out/'benchmark'; trace=out/'recording.trace'
    if Path(args.app_name).name!=args.app_name or not args.app_name.endswith('.app'): raise ValueError('app-name must be one .app filename')
    app=args.products.resolve()/'Profile'/args.app_name/'Contents/MacOS/yl_player_example'
    cmd=[sys.executable,'-B',str(root/'tool/playback_benchmark/run_timed_video_activation.py'),
         '--products',str(args.products.resolve()),'--configuration','Profile','--directory',str(bench),
         '--app-name',args.app_name,'--candidate','--without-thread-checker','--diagnostics','--transport-diagnostics','--trace-gate-token',token]
    if args.long: cmd.append('--long')
    receipt=dict(diagnosticOnly=True,formalAcceptance=False,productionAdmission=False,benchmarkCommand=cmd,token=token,notificationName=name)
    b=None;t=None;stop_sent=False;trigger=None;errors=[];start=time.monotonic()
    tail=RowTail(bench/'rows.jsonl')
    try:
        with (out/'benchmark.log').open('w') as blog, (out/'trace.log').open('w') as tlog:
            b=subprocess.Popen(cmd,cwd=root,stdout=blog,stderr=blog)
            notified=False;seen_settled=False; trace_deadline=None; recorder_started=None
            duration=1320 if args.long else 45
            while b.poll() is None:
                now=time.monotonic()
                if now-start>(1440 if args.long else 300): raise TimeoutError('diagnostic parent deadline')
                request=bench/'trace-request.json'
                if t is None and request.exists():
                    req=json.loads(request.read_text());pid=req['pid']
                    if req['token']!=token or not isinstance(pid,int) or pid<=0: raise RuntimeError('wrong gate identity')
                    actual=subprocess.check_output(['ps','-p',str(pid),'-o','comm='],text=True).strip()
                    if Path(actual).resolve()!=app.resolve(): raise RuntimeError('gate PID is not the owned player')
                    tc=['xcrun','xctrace','record','--template','System Trace','--instrument','Core Animation Server','--instrument','Display',
                        '--attach',str(pid),'--notify-tracing-started',name,'--time-limit','1320s' if args.long else '45s','--output',str(trace)]
                    tc.extend(['--window','10s'])
                    receipt.update(ownedPID=pid,traceCommand=tc,traceRequestedUptime=now)
                    t=subprocess.Popen(tc,stdout=tlog,stderr=tlog);receipt['tracePID']=t.pid
                    trace_deadline=now+60
                    print('Waiting for recorder-start notification, owned PID',pid,flush=True)
                if t is not None:
                    status=t.poll()
                    if status is not None and 'recorderExitObservedUptime' not in receipt:
                        receipt.update(recorderExitObservedUptime=now,recorderObservedExitCode=status)
                    check_recorder(status,now=now,started=recorder_started,settled=seen_settled,stop_sent=stop_sent,duration=duration)
                if t is not None and not notified:
                    if note.received():
                        # Check again after consuming the notification; it may be queued after exit.
                        check_recorder(t.poll(),now=time.monotonic(),started=None,settled=False,stop_sent=False,duration=duration)
                        notified=True;recorder_started=time.monotonic()
                        record=dict(pid=receipt['ownedPID'],token=token,recordingStartedUptime=time.monotonic(),notificationName=name,tracePID=t.pid)
                        tmp=bench/'trace-started.tmp';tmp.write_text(json.dumps(record,indent=2));tmp.replace(bench/'trace-started.json')
                        receipt['notification']=record
                        print('Recorder start confirmed; waiting for native settling probe',flush=True)
                    elif t.poll() is not None: raise RuntimeError('recorder exited before start notification')
                    elif now>trace_deadline: raise TimeoutError('recorder-start notification deadline')
                if not seen_settled and (bench/'trace-settled.json').exists():
                    check_recorder(t.poll(),now=time.monotonic(),started=recorder_started,settled=False,stop_sent=False,duration=duration)
                    receipt['settled']=json.loads((bench/'trace-settled.json').read_text());seen_settled=True
                    print('Native settling confirmed:',receipt['settled'],flush=True)
                if t is not None and not stop_sent and t.poll() is None:
                    if shutil.disk_usage(out).free<4*1024**3:
                        errors.append('capture stopped at 4 GiB free disk boundary');t.send_signal(signal.SIGINT);stop_sent=True
                    elif args.long:
                        row=tail.poll()
                        if row and trigger is None:
                            native=row.get('nativeDiagnostics') or {}
                            events=native.get('backpressureEvents',[])
                            event=next((e for e in events if e.get('enqueueBeganUptime',e.get('endedUptime',0))-e['firstRejectedUptime']>=.06),None)
                            since=native.get('blockedSince')
                            if event or (isinstance(since,(int,float)) and row['uptime']-since>=.06):
                                trigger=dict(detectedUptime=now,event=event,row=row);receipt['trigger']=trigger
                                print('Ready wait trigger captured; recording a 250 ms tail after detection',flush=True)
                        if trigger and now-trigger['detectedUptime']>=.25:
                            t.send_signal(signal.SIGINT);stop_sent=True;receipt['traceStopRequestedUptime']=now
                remaining=.25-(time.monotonic()-trigger['detectedUptime']) if trigger and not stop_sent else .2
                time.sleep(max(.001,min(.2,remaining)))
            receipt['benchmarkExitCode']=b.returncode
    except (Exception,KeyboardInterrupt) as error:
        errors.append(repr(error))
    finally:
        if errors and bench.exists():
            revoke_gate(bench,token,errors)
        if b is not None and b.poll() is None:
            b.send_signal(signal.SIGINT)
            try: b.wait(timeout=30)
            except subprocess.TimeoutExpired:
                b.terminate()
                try:b.wait(timeout=10)
                except subprocess.TimeoutExpired:b.kill();b.wait(timeout=10)
        if t is not None:
            if t.poll() is None and not stop_sent:
                t.send_signal(signal.SIGINT);receipt['traceStopRequestedUptime']=time.monotonic()
            try: receipt['traceExitCode']=t.wait(timeout=300)
            except subprocess.TimeoutExpired:
                errors.append('trace save deadline');t.terminate()
                try:t.wait(timeout=10)
                except subprocess.TimeoutExpired:t.kill();t.wait(timeout=10)
        note.close()
        receipt.update(errors=errors,finishedUptime=time.monotonic(),coverageRequiresTraceExport=True)
        try: (out/'capture-receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
        except OSError as error: errors.append('cannot save capture receipt: '+repr(error))
    print(json.dumps({k:v for k,v in receipt.items() if k not in ('trigger','benchmarkCommand','traceCommand')},indent=2))
    return 0 if not errors and receipt.get('traceExitCode')==0 and receipt.get('benchmarkExitCode')==0 else 1


if __name__=='__main__': raise SystemExit(main())
