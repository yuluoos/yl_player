"""Offline type-level accounting of the frozen decoded EOF length matrix."""
import argparse
import base64
import gzip
import hashlib
import json
from pathlib import Path
import re
from summarize_decoded_resource_matrix import validate_matrix


def sha(data): return hashlib.sha256(data).hexdigest()


def parse_heap(raw, pid):
    processes=re.findall(r'^Process:[^\n]*$',raw,re.M)
    if len(processes)!=1 or not re.fullmatch(r'Process:\s+yl_player_example \['+str(pid)+r'\]\s*',processes[0]):
        raise ValueError('Wrong heap PID')
    totals=re.findall(r'^All zones:\s+(\d+) nodes \((\d+) bytes\)\s*$',raw,re.M)
    headers=list(re.finditer(r'^\s*COUNT\s+BYTES\s+AVG\s+CLASS_NAME\s+TYPE\s+BINARY\s*$',raw,re.M))
    if len(totals)!=1 or len(headers)!=1: raise ValueError('Missing or ambiguous heap table')
    rows=[]
    for line in raw[headers[0].end():].splitlines():
        if not line.strip() or re.fullmatch(r'[\s=]+',line):continue
        match=re.fullmatch(r'\s*(\d+)\s+(\d+)\s+[\d.]+\s{2,}(.+?)\s*',line)
        if not match:raise ValueError('Malformed heap row: '+line)
        count,size=int(match[1]),int(match[2]);fields=re.split(r'\s{2,}',match[3])
        if fields==['non-object']:fields+= [None,None]
        elif len(fields)==2 and fields[0].endswith('(malloc)'):fields.insert(1,None)
        if len(fields)!=3:raise ValueError('Ambiguous heap type columns: '+line)
        key=tuple(fields)
        rows.append(dict(className=key[0],type=key[1],binary=key[2],count=count,bytes=size))
    total=[int(x) for x in totals[0]]
    if not rows or [sum(r[k] for r in rows) for k in ('count','bytes')]!=total:
        raise ValueError('Heap table does not reconcile with All zones')
    return dict(pid=pid,totals=total,rows=rows)


def key(row):return (row['className'],row['type'],row['binary'])


def aggregate(table):
    grouped={}
    for row in table['rows']:
        identity=key(row)
        value=grouped.setdefault(identity,dict(className=identity[0],type=identity[1],binary=identity[2],count=0,bytes=0,tableRows=0))
        value['count']+=row['count'];value['bytes']+=row['bytes'];value['tableRows']+=1
    return grouped


def selected_type(table, class_name, type_name, binary):
    return aggregate(table).get((class_name,type_name,binary))


def compare_tables(before,after):
    left=aggregate(before);right=aggregate(after)
    rows=[]
    for identity in sorted(left.keys()|right.keys(),key=lambda x:tuple(v or '' for v in x)):
        a=left.get(identity);b=right.get(identity)
        # Arithmetic over table listings. A missing type remains null in the
        # endpoints and is not evidence that the runtime object count is zero.
        rows.append(dict(className=identity[0],type=identity[1],binary=identity[2],before=a,after=b,
            bothListed=a is not None and b is not None,
            countDelta=(b['count'] if b else 0)-(a['count'] if a else 0),
            bytesDelta=(b['bytes'] if b else 0)-(a['bytes'] if a else 0)))
    delta=[after['totals'][i]-before['totals'][i] for i in (0,1)]
    if [sum(r[k] for r in rows) for k in ('countDelta','bytesDelta')]!=delta:
        raise ValueError('Type deltas do not reconcile')
    return dict(totalDelta=delta,rows=rows)


def compact_comparison(comparison):
    rows=comparison['rows']
    positive=sorted((r for r in rows if r['bytesDelta']>0),key=lambda r:-r['bytesDelta'])
    negative=sorted((r for r in rows if r['bytesDelta']<0),key=lambda r:r['bytesDelta'])
    return dict(totalDelta=comparison['totalDelta'],
        summedRowDelta=[sum(r[k] for r in rows) for k in ('countDelta','bytesDelta')],
        identitiesCompared=len(rows),topIncreases=positive[:20],topDecreases=negative[:20],
        remainingIncreaseBytes=sum(r['bytesDelta'] for r in positive[20:]),
        remainingDecreaseBytes=sum(r['bytesDelta'] for r in negative[20:]))


SELECTED={
    'lifecycle':('YlAudioCompletionGroup.LifecycleCompletion','Swift','yl_player_example.debug.dylib'),
    'dispatchSources':('dispatch_source_t','ObjC','libdispatch.dylib'),
    'blocks':('__NSMallocBlock__','ObjC','libsystem_blocks.dylib'),
    'swiftClosures':('Closure context','Swift','<unknown>'),
    'pcm':('AVAudioPCMBuffer','ObjC','AVFAudio'),
    'terminalResource':('YlAudioTerminalState.Resource','Swift','yl_player_example.debug.dylib'),
    'untyped':('non-object',None,None),
}


def baseline_adjusted(tables, arm):
    def totals(seconds, phase):return tables[seconds,arm][phase]['totals'][1]
    def selected_delta(seconds, identity):
        endpoints=[selected_type(tables[seconds,arm][phase],*identity) for phase in ('configured','drained')]
        return dict(endpoints=endpoints,listedBytesDelta=sum(sign*(r['bytes'] if r else 0)
            for sign,r in zip((-1,1),endpoints)))
    components={}
    for label in ('lifecycle','dispatchSources','blocks','swiftClosures','untyped'):
        short=selected_delta(4,SELECTED[label]);long=selected_delta(60,SELECTED[label])
        components[label]=dict(at4=short,at60=long,bytesDelta=long['listedBytesDelta']-short['listedBytesDelta'])
    total=(totals(60,'drained')-totals(60,'configured'))-(totals(4,'drained')-totals(4,'configured'))
    named=sum(components[label]['bytesDelta'] for label in ('lifecycle','dispatchSources','blocks','swiftClosures'))
    untyped=components['untyped']['bytesDelta']
    return dict(totalBytesDelta=total,namedFourBytesDelta=named,untypedBytesDelta=untyped,
                otherListedBytesDelta=total-named-untyped,components=components)


def analyze_archive(path):
    data=Path(path).read_bytes();archive=json.loads(data)
    cells=archive['observations'];validate_matrix(cells)
    if archive['identity']!=cells[0]['identity']:raise ValueError('Archive/cell measurement identity mismatch')
    raw_index={}
    for entry in archive['raw']:
        if entry['path'] in raw_index:raise ValueError('Duplicate archive path')
        raw_index[entry['path']]=entry
    output=[];tables={}
    for cell in cells:
        seconds,arm=cell['seconds'],cell['arm'];probes=cell['result']['probes']
        phases={};sources={}
        for probe in probes:
            phase=probe['phase'];name=f'yl-length-final-{seconds}-{arm}/{phase}-heap.txt'
            entry=raw_index[name]
            if entry['encoding']!='gzip+base64':raise ValueError('Unsupported raw encoding')
            raw=gzip.decompress(base64.b64decode(entry['data'],validate=True))
            if len(raw)!=entry['bytes'] or len(raw)!=probe['bytes'] or sha(raw)!=entry['sha256'] or sha(raw)!=probe['sha256']:
                raise ValueError('Archived heap identity mismatch')
            if probe['pid']!=cell['rows'][0]['pid']:raise ValueError('Probe/observation PID mismatch')
            table=parse_heap(raw.decode('utf-8'),probe['pid'])
            if table['totals']!=probe['summaryTotals'] or table['totals']!=probe['tableTotals']:
                raise ValueError('Archived heap totals mismatch')
            phases[phase]=table;sources[phase]=dict(path=name,sha256=sha(raw))
        tables[seconds,arm]=phases
        comparisons={label:compact_comparison(compare_tables(phases[a],phases[b])) for label,a,b in
            (('drainedMinusConfigured','configured','drained'),('disposedMinusDrained','drained','disposed'))}
        output.append(dict(seconds=seconds,arm=arm,submittedBuffers=cell['rows'][1]['modes']['playedSubmissions']+
            cell['rows'][1]['modes']['renderedSubmissions'],sources=sources,phases={p:dict(totals=t["totals"],rawRows=len(t["rows"]),typeIdentities=len(aggregate(t))) for p,t in phases.items()},comparisons=comparisons,
            selected={phase:{label:selected_type(table,*identity) for label,identity in SELECTED.items()}
                      for phase,table in phases.items()}))
    contrasts={arm:compact_comparison(compare_tables(tables[4,arm]['drained'],tables[60,arm]['drained'])) for arm in ('legacy','candidate')}
    return dict(schemaVersion=1,sourceArchive=dict(path=str(path),sha256=sha(data),baseCommit=archive['baseCommit']),
        measurementIdentity=cells[0]['identity'],cells=output,drained60Minus4=contrasts,
        baselineAdjusted60Minus4={arm:baseline_adjusted(tables,arm) for arm in ('legacy','candidate')},
        typeLevelAccounting=True,retainerGraphProven=False,allocationStackProven=False,
        causalityProven=False,defaultEnabled=False,productionAdmission=False,downstreamBoundProven=False,
        missingTypeMeaning='Not separately identified; null must not be interpreted as zero live objects',
        deltaMeaning='Differences of listed table entries; absent endpoints retained as null')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();result=analyze_archive(args.archive)
    result['analysisSourceHashes']={p.name:sha(p.read_bytes()) for p in
        (Path(__file__),*(Path(__file__).with_name(name) for name in
            ('test_decoded_heap_attribution.py','decoded-heap-attribution-protocol.md',
             'summarize_decoded_resource_matrix.py','run_audio_integration_resources.py')))}
    with args.output.open('x') as stream:json.dump(result,stream,ensure_ascii=False,indent=2);stream.write('\n')
