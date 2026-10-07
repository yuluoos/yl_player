"""Bounded local diagnostic control of the owned VM's profiler flag only."""
import http.client
import json
from pathlib import Path
import sys
import time
from memory_mapping import http_rpc, service_uri


def control_profiler(rpc,pid,desired):
    if desired is not None and type(desired) is not bool:raise ValueError('Invalid profiler state')
    start_times=[]
    def identity():
        vm=rpc('getVM',{})
        if vm.get('type')!='VM' or type(vm.get('pid')) is not int or vm['pid']!=pid or type(vm.get('startTime')) is not int or vm['startTime']<=0:
            raise ValueError('VM identity unavailable')
        start_times.append(vm['startTime'])
        groups=[]
        for field,kind,minimum in (('isolateGroups','application',1),('systemIsolateGroups','system',0)):
            rows=vm.get(field)
            if not isinstance(rows,list) or not minimum<=len(rows)<=8 or any(not isinstance(r,dict) for r in rows):
                raise ValueError('VM groups unavailable')
            groups.extend(dict(id=r.get('id'),kind=kind) for r in rows)
        ids=[g['id'] for g in groups]
        if any(not isinstance(i,str) or not 1<=len(i)<=128 for i in ids) or len(set(ids))!=len(ids):
            raise ValueError('Invalid VM group identity')
        return dict(pid=pid,groups=sorted(groups,key=lambda g:g['id']))
    def state():
        result=rpc('getFlagList',{})
        rows=result.get('flags')
        if result.get('type')!='FlagList' or not isinstance(rows,list) or any(not isinstance(r,dict) for r in rows):
            raise ValueError('Flag list unavailable')
        selected=[r for r in rows if r.get('name')=='profiler']
        if len(selected)!=1 or selected[0].get('valueAsString') not in ('true','false'):
            raise ValueError('Profiler state unavailable')
        return selected[0]['valueAsString']=='true'
    started=identity();before=state()
    if desired is not None:
        result=rpc('setFlag',{'name':'profiler','value':'true' if desired else 'false'})
        if result.get('type')!='Success':raise ValueError('Profiler control failed')
    after=state()
    if after!=(before if desired is None else desired) or identity()!=started:
        raise ValueError('Profiler readback or process mismatch')
    # getVM startTime varied by 1ms within an observed process; keep both raw
    # values without using their exact equality as a restart detector.
    return dict(before=before,after=after,requested=desired,vmIdentity=started,vmStartTimes=start_times)


def main(args):
    result=dict(status='unavailable',rpc=[])
    try:
        if len(args)!=4 or args[2] not in ('on','off','observe'):raise ValueError('Expected own log/PID/mode/journal')
        log,pid,mode,journal=Path(args[0]),int(args[1]),args[2],Path(args[3])
        result['pid']=pid
        with journal.open('x'):pass
        rpc=http_rpc(service_uri(log.read_text()),result['rpc'],time.monotonic()+9,journal=journal,allow_profiler_control=mode!='observe')
        result['control']=control_profiler(rpc,pid,None if mode=='observe' else mode=='on')
        result['status']='captured'
    except (OSError,ValueError,TypeError,KeyError,http.client.HTTPException) as e:result['errorType']=type(e).__name__
    print(json.dumps(result,separators=(',',':')))
    return 0 if result['status']=='captured' else 2

if __name__=='__main__':raise SystemExit(main(sys.argv[1:]))
