"""Metadata-only Dart/VM-region observations; never infer address ownership."""
import http.client
import base64
import json
import os
import re
import time
from urllib.parse import urlsplit, urlencode
from memory_categories import parse_vmmap, SIZE


def service_uri(log):
    matches=re.findall(r'Connecting to Flutter application at (\S+)',log)
    if not matches or len(set(matches))!=1:raise ValueError('Missing or mixed service endpoint')
    value=matches[0];p=urlsplit(value)
    if (p.scheme!='http' or p.hostname not in ('127.0.0.1','::1') or not p.port
        or p.username or p.password or p.query or p.fragment or not p.path.endswith('/')):
        raise ValueError('Expected literal loopback service')
    return value


def read_memory(rpc,pid,*,include_system=False):
    def identity():
        v=rpc('getVM',{})
        if v.get('type')!='VM' or type(v.get('pid')) is not int or v['pid']!=pid:
            raise ValueError('VM process mismatch')
        ids=[]
        fields=[('isolateGroups','application',1)]
        if include_system:fields.append(('systemIsolateGroups','system',0))
        for field,kind,minimum in fields:
            groups=v.get(field)
            if not isinstance(groups,list) or not minimum<=len(groups)<=8 or any(not isinstance(g,dict) for g in groups):
                raise ValueError('Unsupported isolate groups')
            ids.extend((g.get('id'),kind) for g in groups)
        names=[i for i,k in ids]
        if any(not isinstance(i,str) or not 1<=len(i)<=128 for i in names) or len(set(names))!=len(names):
            raise ValueError('Invalid isolate groups')
        return sorted(ids)
    ids=identity();result=[]
    for group,kind in ids:
        m=rpc('getIsolateGroupMemoryUsage',{'isolateGroupId':group})
        fields=('heapUsage','heapCapacity','externalUsage')
        if m.get('type')!='MemoryUsage' or any(type(m.get(k)) is not int or not 0<=m[k]<=2**53-1 for k in fields) or m['heapUsage']>m['heapCapacity']:
            raise ValueError('Memory usage unavailable or invalid')
        row=dict(id=group,memory={k:m[k] for k in ('type',*fields)})
        if include_system:row['kind']=kind
        result.append(row)
    if identity()!=ids:raise ValueError('Isolate groups changed')
    return dict(scope='application-and-system-isolate-groups' if include_system else 'non-system-isolate-groups',groups=result,forcedGC=False,addressOwnership=None)


def http_rpc(uri,records,deadline,*,journal,allow_profiler_control=False):
    p=urlsplit(service_uri('Connecting to Flutter application at '+uri))
    def persist(event):
        with journal.open('a') as stream:
            stream.write(json.dumps(event,separators=(',',':'))+'\n')
            stream.flush();os.fsync(stream.fileno())
    sequence=0
    def rpc(method,params):
        nonlocal sequence
        if method=='setFlag':
            if not allow_profiler_control or params not in ({'name':'profiler','value':'true'},{'name':'profiler','value':'false'}):
                raise ValueError('Unsupported profiler control')
        elif method not in ('getVM','getIsolateGroupMemoryUsage','getFlagList'):
            raise ValueError('Unsupported read-only method')
        if method=='getFlagList' and params:raise ValueError('Unexpected flag-list parameters')
        remaining=deadline-time.monotonic()
        if remaining<=0:raise TimeoutError('Memory observation deadline')
        sequence+=1
        identity=dict(sequence=sequence,method=method)
        persist(dict(identity,stage='request',params=params))
        connection=http.client.HTTPConnection(p.hostname,p.port,timeout=min(2,remaining))
        try:
            connection.request('GET',p.path+method+('?' + urlencode(params) if params else ''))
            response=connection.getresponse()
            persist(dict(identity,stage='headers',httpStatus=response.status))
            raw=bytearray()
            while len(raw)<=1048576:
                if time.monotonic()>=deadline:raise TimeoutError('Memory observation deadline')
                chunk=response.read1(min(65536,1048577-len(raw)))
                if not chunk:break
                kept=chunk[:max(0,1048576-len(raw))]
                if kept:persist(dict(identity,stage='body',data=base64.b64encode(kept).decode()))
                raw.extend(chunk)
            if len(raw)>1048576:
                persist(dict(identity,stage='limit',capturedBytes=1048576,observedBytes=len(raw)))
                raise ValueError('Response limit')
            # Persist raw bytes BEFORE parsing: invalid JSON and hard termination
            # cannot erase completed headers/body chunks. No endpoint is logged.
            value=json.loads(raw)
            records.append(dict(method=method,params=params,httpStatus=response.status,response=value))
            if response.status!=200 or not isinstance(value,dict) or 'error' in value:raise ValueError('RPC unavailable')
            result=value.get('result',value)
            if not isinstance(result,dict):raise ValueError('Invalid RPC result')
            return result
        finally:connection.close()
    return rpc


def untagged_regions(text,pid):
    summary=parse_vmmap(text,pid)
    rows=[];bounds=[]
    for line in text.splitlines():
        if not line.startswith('Untagged ') or '[' not in line:continue
        # vmmap lists reserved address space as its own summary category.
        if line.startswith('Untagged (reserved) '):continue
        m=re.fullmatch(r'Untagged\s+([0-9a-fA-F]+)-([0-9a-fA-F]+)\s+\[\s*('+SIZE+r')\s+('+SIZE+r')\s+('+SIZE+r')\s+('+SIZE+r')\s*\]\s+([rwx-]{3}/[rwx-]{3})\s+SM=([A-Z]+)\s*',line)
        if not m:raise ValueError('Unknown untagged region format')
        start,end=int(m[1],16),int(m[2],16)
        if end<=start or any(start<b and end>a for a,b in bounds):raise ValueError('Overlapping or invalid region')
        bounds.append((start,end))
        rows.append(dict(start=hex(start),endExclusive=hex(end),virtualBytes=end-start,
                         virtualDisplay=m[3],residentSize=m[4],dirtySize=m[5],swappedSize=m[6],
                         protection=m[7],sharing=m[8],owner=None))
    count=summary['regions'].get('Untagged',{}).get('regionCount',0)
    if len(rows)!=count:raise ValueError('Incomplete untagged region table')
    return rows


def main():
    import json
    import sys
    from pathlib import Path
    result=dict(status='unavailable',rpc=[],memory=None)
    try:
        args=sys.argv[1:]
        include_system=bool(args and args[0]=='--include-system')
        if include_system:args=args[1:]
        if len(args) not in (2,3):raise ValueError('Expected own log, PID and optional journal')
        journal=Path(args[2]) if len(args)==3 else Path(args[0]).with_suffix('.rpc.jsonl')
        with journal.open('x'):pass
        pid=int(args[1]);result['pid']=pid
        uri=service_uri(Path(args[0]).read_text())
        result['memory']=read_memory(http_rpc(uri,result['rpc'],time.monotonic()+9,journal=journal),pid,include_system=include_system)
        result['status']='captured'
    except (OSError,ValueError,TypeError,KeyError,http.client.HTTPException) as e:
        result['errorType']=type(e).__name__
    print(json.dumps(result,separators=(',',':')))
    return 0 if result['status']=='captured' else 2

if __name__=='__main__':raise SystemExit(main())
