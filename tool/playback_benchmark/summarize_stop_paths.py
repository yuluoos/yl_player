"""Same-build EOF stop comparison between legacy and candidate submission paths."""
import argparse
import json
from pathlib import Path
from summarize_callback_wrappers import load_wrapper
from summarize_stop_timing import validate_timing_cell


def validate_paths(cells):
    if len(cells)!=2 or {c['arm'] for c in cells}!={'legacy','candidate'}:raise ValueError('Missing/duplicate stop path')
    output=[]
    for c in cells:
        result=c['result']
        if c['identity']!=cells[0]['identity'] or c['seconds']!=60 or result['callbackWrapping']!='transparent' or result['boundaryMode']!='stop':raise ValueError('Wrong build/source/profile')
        if not result['complete'] or result['testExitCode']!=0 or result['errors']:raise ValueError('Failed stop path')
        if [p['phase'] for p in result['probes']]!=['configured','drained','intervened','disposed'] or not all(p['valid'] for p in result['probes']):raise ValueError('Incomplete stop heap')
        timing=validate_timing_cell(c,candidate=c['arm']=='candidate')
        output.append(dict(arm=c['arm'],timing=timing,modes=c['rows'][1]['modes'],
            heapTotals={p['phase']:p['summaryTotals'] for p in result['probes']},selected=c['selected']))
    if len({c['rows'][0]['pid'] for c in cells})!=2:raise ValueError('Reused stop process')
    windows=sorted((c['rows'][0]['uptime'],c['rows'][-1]['uptime']) for c in cells)
    if windows[1][0]<=windows[0][1]:raise ValueError('Overlapping stop observations')
    legacy=next(c for c in output if c['arm']=='legacy');candidate=next(c for c in output if c['arm']=='candidate')
    return dict(cells=output,candidateMinusLegacyStopSeconds=candidate['timing']['nativeStopSeconds']-legacy['timing']['nativeStopSeconds'],
        defaultEnabled=False,productionAdmission=False,downstreamBoundProven=False,statisticalImprovementProven=False,
        automaticEOFStopValidated=False,replaySeekValidated=False)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('directories',nargs=2,type=Path)
    args=parser.parse_args();print(json.dumps(validate_paths([load_wrapper(p) for p in args.directories]),indent=2))
