"""Same-build stopped-player versus paused-control EOF heap comparison."""
import argparse
import json
from pathlib import Path
from run_audio_integration_resources import validate_stop_rows
from summarize_callback_wrappers import load_wrapper


def validate_pair(cells):
    if len(cells)!=2 or {c['result']['boundaryMode'] for c in cells}!={'hold','stop'}:raise ValueError('Missing/duplicate stop arm')
    output=[]
    for c in cells:
        result=c['result'];mode=result['boundaryMode']
        if c['identity']!=cells[0]['identity'] or c['arm']!='legacy' or c['seconds']!=60 or result['callbackWrapping']!='transparent':raise ValueError('Wrong build/source/path')
        if not result['complete'] or result['testExitCode']!=0 or result['errors']:raise ValueError('Failed stop arm')
        if [p['phase'] for p in result['probes']]!=['configured','drained','intervened','disposed'] or not all(p['valid'] for p in result['probes']):raise ValueError('Incomplete stop heap')
        observation=validate_stop_rows(c['rows'],mode,60,'decoded-60.mkv')
        heaps={p['phase']:p['summaryTotals'] for p in result['probes']}
        output.append(dict(boundaryMode=mode,observation=observation,heapTotals=heaps,selected=c['selected'],
            intervenedMinusDrainedBytes=heaps['intervened'][1]-heaps['drained'][1]))
    if len({c['rows'][0]['pid'] for c in cells})!=2:raise ValueError('Reused stop process')
    windows=sorted((c['rows'][0]['uptime'],c['rows'][-1]['uptime']) for c in cells)
    if windows[1][0]<=windows[0][1]:raise ValueError('Overlapping stop observations')
    hold=next(c for c in output if c['boundaryMode']=='hold');stop=next(c for c in output if c['boundaryMode']=='stop')
    types={}
    for label in hold['selected']['drained']:
        endpoints={mode:{p:cell['selected'][p][label] for p in ('drained','intervened')} for mode,cell in (('hold',hold),('stop',stop))}
        # Missing listings stay null; only arithmetic contributions use zero.
        delta=lambda mode:sum(sign*(endpoints[mode][p]['bytes'] if endpoints[mode][p] else 0) for sign,p in ((1,'intervened'),(-1,'drained')))
        types[label]=dict(endpoints=endpoints,listedStopMinusHoldDeltaBytes=delta('stop')-delta('hold'))
    return dict(cells=output,typeContrasts=types,stopMinusHoldDeltaBytes=stop['intervenedMinusDrainedBytes']-hold['intervenedMinusDrainedBytes'],
        defaultEnabled=False,productionAdmission=False,downstreamBoundProven=False,exactRetainerProven=False,statisticalImprovementProven=False)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('directories',nargs=2,type=Path)
    args=parser.parse_args();print(json.dumps(validate_pair([load_wrapper(p) for p in args.directories]),indent=2))
