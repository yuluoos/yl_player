"""Offline four-cell R2 heap comparison; observations never imply admission."""
import argparse
import json
import math
from pathlib import Path
from attribute_decoded_heap import parse_heap, selected_type, SELECTED
from run_audio_integration_resources import digest
from run_lifecycle_resources import validate_rows, PHASES


def load_cell(directory):
    directory=Path(directory)
    result=json.loads((directory/'result.json').read_text())
    rows=[json.loads(x) for x in (directory/'rows.jsonl').read_text().splitlines()]
    heaps={}
    for probe in result['probes']:
        if probe['phase'] not in PHASES:raise ValueError('Unknown heap phase')
        file=directory/(probe['phase']+'-heap.txt');raw=file.read_bytes()
        if len(raw)!=probe['bytes'] or digest(file)!=probe['sha256']:raise ValueError('Changed raw heap')
        table=parse_heap(raw.decode(),probe['pid'])
        heaps[probe['phase']]=dict(totals=table['totals'],selected={k:selected_type(table,*v) for k,v in SELECTED.items()})
    return dict(arm=result['arm'],kind=result['kind'],result=result,rows=rows,identity=json.loads((directory/'identity.json').read_text()),heaps=heaps)


def validate_matrix(cells):
    expected={(a,k) for a in ('legacy','candidate') for k in ('seek','load-close')}
    if len(cells)!=4 or {(c['arm'],c['kind']) for c in cells}!=expected:raise ValueError('Missing/duplicate lifecycle cell')
    output=[]
    for c in cells:
        r=c['result'];rows=c['rows']
        if c['identity']!=cells[0]['identity']:raise ValueError('Changed build/material identity')
        if (r['arm'],r['kind'],r['rounds'])!=(c['arm'],c['kind'],6):raise ValueError('Result profile mismatch')
        if not r['complete'] or r['testExitCode']!=0 or r['errors']:raise ValueError('Failed lifecycle cell')
        observation=validate_rows(rows,c['arm']=='candidate',c['kind'])
        if [p['phase'] for p in r['probes']]!=PHASES:raise ValueError('Missing/duplicate heap')
        for p in r['probes']:
            i=next(i for i,row in enumerate(rows) if row['phase']==p['phase'])
            if not p['valid'] or p['pid']!=rows[0]['pid']:raise ValueError('Invalid/mismatched heap process')
            if not all(math.isfinite(p[k]) for k in ('startedUptime','endedUptime')) or not rows[i]['uptime']<=p['startedUptime']<=p['endedUptime']<rows[i+1]['uptime']:raise ValueError('Heap outside paused checkpoint')
            if p['summaryTotals']!=p['tableTotals'] or p['summaryTotals']!=c['heaps'][p['phase']]['totals']:raise ValueError('Heap totals mismatch')
        baseline=c['heaps']['baseline']['totals'][1]
        output.append(dict(arm=c['arm'],kind=c['kind'],observation=observation,heaps=c['heaps'],baselineRelativeBytes={k:v['totals'][1]-baseline for k,v in c['heaps'].items()},cycle6MinusCycle1Bytes=c['heaps']['cycle6']['totals'][1]-c['heaps']['cycle1']['totals'][1]))
    if len({c['rows'][0]['pid'] for c in cells})!=4:raise ValueError('Reused process')
    windows=sorted((c['rows'][0]['uptime'],c['rows'][-1]['uptime']) for c in cells)
    if any(b[0]<=a[1] for a,b in zip(windows,windows[1:])):raise ValueError('Overlapping processes')
    return dict(cells=output,defaultEnabled=False,productionAdmission=False,downstreamBoundProven=False,statisticalImprovementProven=False)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('directories',nargs=4,type=Path)
    a=p.parse_args();print(json.dumps(validate_matrix([load_cell(d) for d in a.directories]),indent=2))
