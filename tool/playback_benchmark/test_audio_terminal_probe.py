import copy
import unittest
from run_audio_terminal_probe import validate_rows


def fixture(scenario='refill'):
    target=2000 if scenario=='refill' else 3 if scenario=='pausedEOF' else 1
    phases=['configured']+(['holding200','holding2000'] if scenario=='refill' else [])+['observed','disposed']
    rows=[]
    for phase in phases:
        hold=phase.startswith('holding');n=int(phase[7:]) if hold else 0 if phase=='configured' else target
        complete=phase in ('observed','disposed');count=n if complete else max(0,n-1)
        events=[dict(ordinal=i,terminal=complete and i==target,rawUs=200+i) for i in range(1,count+1)]
        submissions=[dict(ordinal=i,terminal=e['terminal'],frames=1024,rawUs=100) for i,e in enumerate(events,1)]
        pending=1 if hold else 0
        rows.append(dict(phase=phase,scenario=scenario,pid=42,accepted=n,events=events,submissions=submissions,
            pending=pending,pendingBytes=pending*8192,pendingDurationUs=pending*21333,
            ledgerBytes=pending*8192,timelineUs=pending*21333,alivePCM=pending,ledgerPeak=min(24,n)*8192,
            drained=phase=='observed',inputFinished=phase=='observed',peakCount=min(24,n),
            samples=[] if phase=='configured' else [dict(rawUs=5000,pending=pending,ledgerBytes=pending*8192,
                bytes=pending*8192,durationUs=pending*21333,drained=phase=='observed',playing=True)],
            actions=[dict(name='play',rawUs=150)]+([dict(name='EOF',rawUs=110 if scenario=='pausedEOF' else 180,playing=scenario!='pausedEOF')] if complete else [])))
        if scenario=='pausedEOF' and phase!='configured':
            rows[-1]['samples'].insert(0,dict(rawUs=120,pending=3,bytes=24576,durationUs=63999,
                ledgerBytes=24576,drained=False,playing=False))
    return rows


class TerminalProbeTests(unittest.TestCase):
    def test_accepts_complete_owned_experiments(self):
        for scenario in ('refill','single','pausedEOF'):
            self.assertEqual(validate_rows(fixture(scenario),scenario,42)['terminalCallbacks'],1)

    def test_requires_real_charged_tail_at_each_starvation_checkpoint(self):
        for field,value in [('pending',0),('ledgerBytes',0),('timelineUs',0),('alivePCM',0),('drained',True)]:
            rows=fixture();rows[1][field]=value
            with self.assertRaises(ValueError):validate_rows(rows,'refill',42)

    def test_rejects_missing_duplicate_or_intermediate_terminal(self):
        for modify in (lambda r:r[-2]['events'].pop(),lambda r:r[-2]['events'].append(r[-2]['events'][0]),
                       lambda r:r[1]['events'][0].update(terminal=True),lambda r:r[-2]['submissions'][0].update(frames=0)):
            rows=fixture();modify(rows)
            with self.assertRaises(ValueError):validate_rows(rows,'refill',42)

    def test_rejects_unbounded_ledger_and_early_drain(self):
        for modify in (lambda r:r[1]['samples'][0].update(ledgerBytes=196609),
                       lambda r:r[-2]['samples'][0].update(rawUs=150),
                       lambda r:r[-2].update(actions=[]),lambda r:r[-2]['samples'][0].update(drained=False)):
            rows=fixture();modify(rows)
            with self.assertRaises(ValueError):validate_rows(rows,'refill',42)

    def test_rejects_transient_ledger_peak_and_drain_before_EOF(self):
        rows=fixture();rows[-2]['ledgerPeak']=196609
        with self.subTest('transient ledger peak'):
            with self.assertRaises(ValueError):validate_rows(rows,'refill',42)
        rows=fixture();row=rows[-2]
        row['actions'][-1]['rawUs']=4000
        early=copy.deepcopy(row['samples'][-1]);early['rawUs']=3000
        row['samples'].insert(0,early)
        with self.subTest('drain before EOF'):
            with self.assertRaises(ValueError):validate_rows(rows,'refill',42)

    def test_requires_all_phases_and_real_paused_EOF(self):
        rows=fixture();rows.pop(1)
        with self.assertRaises(ValueError):validate_rows(rows,'refill',42)
        rows=fixture('pausedEOF');rows[-2]['actions'][-1]['playing']=True
        with self.assertRaises(ValueError):validate_rows(rows,'pausedEOF',42)


if __name__=='__main__':unittest.main()
