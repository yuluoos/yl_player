import copy
import unittest
from run_lifecycle_resources import validate_rows


def rows(candidate=False, kind='seek'):
    out=[]
    for i,phase in enumerate(['baseline']+[f'cycle{n}' for n in range(1,7)]+['disposed','disposedLater']):
        cycle=min(i,6);active=kind=='seek' and 1<=i<=6
        out.append(dict(phase=phase,cycle=cycle,rounds=6,pid=12,uptime=i*4+1,candidate=candidate,kind=kind,
            completed=cycle,firstFrames=(1 if cycle else 0) if kind=='seek' else cycle,
            sessions=(1 if cycle else 0) if kind=='seek' else cycle,playedSubmissions=cycle*(1 if candidate else 188),
            renderedSubmissions=cycle*187 if candidate else 0,videoFrames=cycle*96,failures=0,retries=0,publications=min(i,7)*5,
            callbackObservation='unobserved',playedCallbacks=None,renderedCallbacks=None,nativePlaying=False,
            pending=False,ownedBytes=0,ledgerBytes=100 if active else 0,retiredEntryAlive=False,
            activeGraph=active,attachedNodes=4 if active else 0,engineRunning=active,submissionAnchor=active and candidate))
    return out


class LifecycleRowsTests(unittest.TestCase):
    def test_valid_fixed_profiles(self):
        for c in (False,True):
            for k in ('seek','load-close'):
                result=validate_rows(rows(c,k),c,k)
                self.assertEqual(result['cycles'],6)
                self.assertFalse(result['downstreamBoundProven'])

    def test_rejects_missing_or_mutated_proof(self):
        mutations=[lambda r:r.pop(),lambda r:r[3].update(cycle=2),lambda r:r[4].update(pid=13),
            lambda r:r[3].update(candidate=False),lambda r:r[2].update(rounds=5),
            lambda r:r[2].update(nativePlaying=True),lambda r:r[2].update(pending=True),
            lambda r:r[2].update(ownedBytes=1),lambda r:r[2].update(completed=1),
            lambda r:r[2].update(firstFrames=2),lambda r:r[2].update(sessions=2),
            lambda r:r[2].update(playedSubmissions=8),lambda r:r[2].update(renderedSubmissions=0),
            lambda r:r[2].update(videoFrames=96),lambda r:r[2].update(failures=1),
            lambda r:r[2].update(submissionAnchor=False),lambda r:r[2].update(engineRunning=False),
            lambda r:r[2].update(playedCallbacks=0),lambda r:r[2].update(uptime=float('nan')),
            lambda r:r[-1].update(ledgerBytes=1),lambda r:r[-1].update(retiredEntryAlive=True),
            lambda r:r[-1].update(renderedSubmissions=12345),lambda r:r[-1].update(publications=999),lambda r:r[2].update(retries=1),lambda r:r[-1].update(uptime=r[-2]['uptime']+1)]
        for mutate in mutations:
            value=rows(True);mutate(value)
            with self.subTest(mutate=mutate),self.assertRaises(ValueError):validate_rows(value,True,'seek')

    def test_load_close_requires_released_graph_each_round(self):
        for field,value in [('activeGraph',True),('attachedNodes',4),('ledgerBytes',1),('sessions',1)]:
            r=rows(False,'load-close');r[3][field]=value
            with self.subTest(field=field),self.assertRaises(ValueError):validate_rows(r,False,'load-close')

from summarize_lifecycle_resources import validate_matrix


def cells():
    result=[]
    for i,(a,k) in enumerate((('legacy','seek'),('candidate','seek'),('legacy','load-close'),('candidate','load-close'))):
        r=rows(a=='candidate',k)
        for row in r:row['pid']+=i;row['uptime']+=i*100
        probes=[dict(phase=p,valid=True,pid=r[0]['pid'],summaryTotals=[1,100],tableTotals=[1,100],startedUptime=next(x['uptime'] for x in r if x['phase']==p)+.1,endedUptime=next(x['uptime'] for x in r if x['phase']==p)+.2) for p in ['baseline','cycle1','cycle3','cycle6','disposed']]
        result.append(dict(arm=a,kind=k,rows=r,identity={'source':1},result=dict(arm=a,kind=k,rounds=6,complete=True,testExitCode=0,errors=[],probes=probes),heaps={p['phase']:dict(totals=[1,100],selected={'lifecycle':None}) for p in probes}))
    return result


class LifecycleMatrixTests(unittest.TestCase):
    def test_reports_raw_deltas_without_bound_claim(self):
        r=validate_matrix(cells())
        self.assertEqual(len(r['cells']),4)
        self.assertEqual(r['cells'][0]['cycle6MinusCycle1Bytes'],0)
        self.assertFalse(r['downstreamBoundProven'])

    def test_rejects_mixed_failed_or_unmatched_cells(self):
        mutations=[lambda c:c.pop(),lambda c:c[1].update(arm='legacy'),lambda c:c[1].update(identity={}),
            lambda c:c[1]['result'].update(complete=False),lambda c:c[1]['result'].update(kind='load-close'),
            lambda c:c[1]['result']['probes'].pop(),lambda c:c[1]['result']['probes'][0].update(valid=False),
            lambda c:c[1]['result']['probes'][0].update(pid=999),lambda c:c[1]['result']['probes'][0].update(startedUptime=0),
            lambda c:c[1]['heaps']['cycle1'].update(totals=[1,101]),
            lambda c:[r.update(pid=12) for r in c[1]['rows']],lambda c:[r.update(uptime=r['uptime']-100) for r in c[1]['rows']]]
        for mutate in mutations:
            c=cells();mutate(c)
            with self.subTest(mutate=mutate),self.assertRaises(ValueError):validate_matrix(c)
