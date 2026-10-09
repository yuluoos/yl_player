"""Same-build wrapper intervention; callbacks in transparent mode are unobserved."""
import argparse
import json
from pathlib import Path
from attribute_decoded_heap import SELECTED, parse_heap, selected_type
from run_audio_integration_resources import PHASES, digest, validate_decoded_rows
from summarize_decoded_resource_matrix import load_cell


def validate_wrappers(cells):
    expected={(a,w) for a in ('legacy','candidate') for w in ('wrapped','transparent')}
    if len(cells)!=4 or {(c['arm'],c['result']['callbackWrapping']) for c in cells}!=expected:
        raise ValueError('Missing/duplicate wrapper cell')
    output=[];counts=[]
    for c in cells:
        result=c['result'];wrapping=result['callbackWrapping']
        if c['identity']!=cells[0]['identity'] or c['seconds']!=60:raise ValueError('Mixed build or length')
        if not result['complete'] or result['testExitCode']!=0 or result['errors']:raise ValueError('Failed wrapper cell')
        if [p['phase'] for p in result['probes']]!=list(PHASES) or not all(p['valid'] for p in result['probes']):
            raise ValueError('Incomplete wrapper heap')
        observation=validate_decoded_rows(c['rows'],c['arm']=='candidate',60,'decoded-60.mkv',wrapping)
        modes=observation['modes'];count=modes['playedSubmissions']+modes['renderedSubmissions'];counts.append(count)
        heaps={p['phase']:p['summaryTotals'] for p in result['probes']}
        output.append(dict(arm=c['arm'],callbackWrapping=wrapping,submittedBuffers=count,
            nativeCallbackCountsObserved=observation['nativeCallbackCountsObserved'],modes=modes,
            playbackElapsedSeconds=observation['playbackElapsedSeconds'],heapTotals=heaps,selected=c['selected']))
    if len(set(counts))!=1 or counts[0]!=2813:raise ValueError('Unexpected fixture submission counts')
    if len({c['rows'][0]['pid'] for c in cells})!=4:raise ValueError('Reused wrapper process')
    windows=sorted((c['rows'][0]['uptime'],c['rows'][-1]['uptime']) for c in cells)
    if any(b[0]<=a[1] for a,b in zip(windows,windows[1:])):raise ValueError('Overlapping wrapper observations')
    differences={}
    for arm in ('legacy','candidate'):
        wrapped=next(c for c in output if c['arm']==arm and c['callbackWrapping']=='wrapped')
        direct=next(c for c in output if c['arm']==arm and c['callbackWrapping']=='transparent')
        delta=lambda c:c['heapTotals']['drained'][1]-c['heapTotals']['configured'][1]
        differences[arm]=dict(wrappedDrainedDelta=delta(wrapped),transparentDrainedDelta=delta(direct),
            adjustedWrappedMinusTransparentBytes=delta(wrapped)-delta(direct))
    return dict(cells=output,wrapperContrasts=differences,defaultEnabled=False,productionAdmission=False,
                downstreamBoundProven=False,statisticalImprovementProven=False,exactWrapperCostProven=False)


def load_wrapper(directory):
    directory=Path(directory);cell=load_cell(directory);selected={}
    for p in cell['result']['probes']:
        file=directory/(p['phase']+'-heap.txt');raw=file.read_bytes()
        if len(raw)!=p['bytes'] or digest(file)!=p['sha256']:raise ValueError('Heap changed')
        if p['pid']!=cell['rows'][0]['pid']:raise ValueError('Heap PID changed')
        table=parse_heap(raw.decode(),p['pid'])
        if table['totals']!=p['summaryTotals'] or table['totals']!=p['tableTotals']:raise ValueError('Heap totals changed')
        selected[p['phase']]={label:selected_type(table,*identity) for label,identity in SELECTED.items()}
    cell['selected']=selected
    return cell


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('directories',nargs=4,type=Path)
    args=parser.parse_args();print(json.dumps(validate_wrappers([load_wrapper(p) for p in args.directories]),indent=2))
