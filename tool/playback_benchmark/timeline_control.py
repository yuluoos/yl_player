"""Owned-VM Timeline streams control with actual readbacks; no timeline clearing."""
import http.client
import json
from pathlib import Path
import sys
import time
from memory_mapping import http_rpc, service_uri
from profiler_control import control_profiler

STREAMS=['Dart','Embedder','GC','Microtask']


def control_timeline(rpc,pid,mode):
    if mode not in ('on','off','observe'):raise ValueError('Invalid timeline mode')
    profiler=control_profiler(rpc,pid,None if mode=='observe' else False)
    if profiler['after'] is not False:raise ValueError('Profiler must be off')
    def state():
        r=rpc('getVMTimelineFlags',{})
        if r.get('type')!='TimelineFlags' or not isinstance(r.get('recorderName'),str) or r['recorderName'].lower() in ('','null'):
            raise ValueError('Timeline recorder unavailable')
        for key in ('availableStreams','recordedStreams'):
            rows=r.get(key)
            if not isinstance(rows,list) or len(rows)>64 or any(not isinstance(x,str) or not 1<=len(x)<=128 for x in rows) or len(set(rows))!=len(rows):
                raise ValueError('Invalid timeline streams')
        if not set(r['recordedStreams'])<=set(r['availableStreams']):raise ValueError('Unknown active streams')
        return {k:r[k] for k in ('recorderName','availableStreams','recordedStreams')}
    before=state();desired=None if mode=='observe' else STREAMS if mode=='on' else []
    if desired is not None:
        if not set(desired)<=set(before['availableStreams']):raise ValueError('Required streams unavailable')
        if rpc('setVMTimelineFlags',{'recordedStreams':desired}).get('type')!='Success':raise ValueError('Timeline control failed')
    after=state()
    if (set(after['recordedStreams'])!=set(before['recordedStreams'] if desired is None else desired)
        or after['recorderName']!=before['recorderName'] or set(after['availableStreams'])!=set(before['availableStreams'])):
        raise ValueError('Timeline readback mismatch')
    final=control_profiler(rpc,pid,None)
    if final['after'] is not False or final['vmIdentity']!=profiler['vmIdentity']:raise ValueError('VM identity or profiler changed')
    return dict(before=before,after=after,requested=desired,vmIdentity=profiler['vmIdentity'],profilerBefore=profiler,profilerAfter=final)


def main(args):
    result=dict(status='unavailable',rpc=[])
    try:
        if len(args)!=4 or args[2] not in ('on','off','observe'):raise ValueError('Expected own log/PID/mode/journal')
        log,pid,mode,journal=Path(args[0]),int(args[1]),args[2],Path(args[3]);result['pid']=pid
        with journal.open('x'):pass
        rpc=http_rpc(service_uri(log.read_text()),result['rpc'],time.monotonic()+9,journal=journal,
                     allow_profiler_control=mode!='observe',allow_timeline_control=mode!='observe')
        result['control']=control_timeline(rpc,pid,mode);result['status']='captured'
    except (OSError,ValueError,TypeError,KeyError,http.client.HTTPException) as e:result['errorType']=type(e).__name__
    print(json.dumps(result,separators=(',',':')))
    return 0 if result['status']=='captured' else 2

if __name__=='__main__':raise SystemExit(main(sys.argv[1:]))
