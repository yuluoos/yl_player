"""Validate a six-process decoded EOF matrix; report measurements, not admission."""
import argparse
import json
from pathlib import Path
from run_audio_integration_resources import PHASES, digest, validate_decoded_rows


def validate_matrix(cells):
    expected={(seconds, arm) for seconds in (4,30,60) for arm in ('legacy','candidate')}
    if len(cells)!=6 or {(c['seconds'],c['arm']) for c in cells}!=expected:
        raise ValueError('Missing or duplicate matrix cell')
    output=[];counts={}
    for cell in cells:
        seconds,arm=cell['seconds'],cell['arm'];result=cell['result']
        if cell['identity']!=cells[0]['identity']:
            raise ValueError('Source/binary identity changed between cells')
        if not result['complete'] or result['testExitCode']!=0 or result['errors']:
            raise ValueError('Failed matrix cell')
        if [p['phase'] for p in result['probes']]!=list(PHASES) or not all(p['valid'] for p in result['probes']):
            raise ValueError('Incomplete heap captures')
        observation=validate_decoded_rows(cell['rows'],arm=='candidate',seconds,f'decoded-{seconds}.mkv')
        modes=observation['modes'];count=modes['playedSubmissions']+modes['renderedSubmissions']
        counts[seconds,arm]=count
        heaps={p['phase']:p['summaryTotals'] for p in result['probes']}
        output.append(dict(seconds=seconds,arm=arm,submittedBuffers=count,
            playbackElapsedSeconds=observation['playbackElapsedSeconds'],heapTotals=heaps,modes=modes,
            resources={r['phase']:{key:r[key] for key in
                ('rssBytes','footprintBytes','ledgerBytes','ledgerPeak','ownedBytes','retainedEventCount')}
                for r in cell['rows']},
            drainedMinusConfiguredBytes=heaps['drained'][1]-heaps['configured'][1],
            disposedMinusConfiguredBytes=heaps['disposed'][1]-heaps['configured'][1]))
    for seconds in (4,30,60):
        if counts[seconds,'legacy']!=counts[seconds,'candidate']:
            raise ValueError('Arms did not submit equal decoded buffers')
    for arm in ('legacy','candidate'):
        if counts[30,arm]<=5*counts[4,arm] or counts[60,arm]<=1.8*counts[30,arm]:
            raise ValueError('Submission count did not grow with length')
    return dict(cells=output,defaultEnabled=False,productionAdmission=False,
                downstreamBoundProven=False,liveHeapProof=False,statisticalImprovementProven=False)


def load_cell(directory):
    directory=Path(directory)
    result=json.loads((directory/'result.json').read_text())
    for probe in result['probes']:
        if digest(directory/(probe['phase']+'-heap.txt'))!=probe['sha256']:
            raise ValueError('Raw heap changed after capture')
    return dict(arm=result['arm'],seconds=result['decodedSeconds'],result=result,
        identity=json.loads((directory/'identity.json').read_text()),
        rows=[json.loads(line) for line in (directory/'rows.jsonl').read_text().splitlines()])


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directories',nargs=6,type=Path)
    args=parser.parse_args()
    print(json.dumps(validate_matrix([load_cell(p) for p in args.directories]),indent=2))
