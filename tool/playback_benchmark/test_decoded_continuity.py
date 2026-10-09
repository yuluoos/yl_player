import copy
import json
from pathlib import Path
import tempfile
import unittest
from decoded_continuity import validate


def rows():
    result=[]
    for i in range(7):
        result.append(dict(phase='playing',pid=42,generation=17,uptime=10+i*5,audioUs=2000000+i*5000000,
            positionUs=2000000+i*5000000,videoPTS=1990000+i*5000000,videoFrames=48+i*120,
            published=48+i*120,maxLagUs=20000,orderErrors=0,dropped=0,failures=[],candidate=True,
            nativePlaying=True,rendererCount=1,ledgerBytes=8192,pending=True))
        result[-1].update(directPublished=0,frameAgeUs=0,modes=dict(renderedSubmissions=100+i*235,
            renderedCallbacks=80+i*235,playedSubmissions=0,playedCallbacks=0))
    for phase,at in [('disposed',41),('disposedLater',43)]:
        r=copy.deepcopy(result[-1]);r.update(phase=phase,uptime=at,ledgerBytes=0,pending=False,nativePlaying=False);result.append(r)
    return result


class DecodedContinuityTests(unittest.TestCase):
    def test_long_requires_matching_successful_short_evidence(self):
        from run_decoded_continuity import require_short_gate
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp);identity=dict(sourceHashes={'a':'sha'},binaryHashes={'b':'sha'})
            (path/'identity.json').write_text(json.dumps(identity))
            (path/'result.json').write_text(json.dumps(dict(complete=True,kind='short',exitCode=0)))
            (path/'rows.jsonl').write_text(''.join(json.dumps(r)+'\n' for r in rows()))
            require_short_gate(path,identity)
            with self.assertRaises(ValueError):require_short_gate(None,identity)
            with self.assertRaises(ValueError):require_short_gate(path,{})
            (path/'result.json').write_text(json.dumps(dict(complete=False,kind='short',exitCode=0)))
            with self.assertRaises(ValueError):require_short_gate(path,identity)
    def test_anchor_flag_does_not_prove_candidate_mode(self):
        for modes in [dict(renderedSubmissions=0,renderedCallbacks=0,playedSubmissions=100,playedCallbacks=80),
                      dict(renderedSubmissions=100,renderedCallbacks=80,playedSubmissions=1,playedCallbacks=1)]:
            r=rows();r[3]['modes']=modes
            with self.assertRaises(ValueError):validate(r,30)

    def test_direct_first_frame_and_disposal_drop_are_separate(self):
        r=rows()
        for row in r:row['published']+=1;row['directPublished']=1
        r[-1]['dropped']=1;r[-2]['dropped']=1
        self.assertEqual(validate(r,30)['durationSeconds'],30)
        r[2]['directPublished']=2
        with self.assertRaises(ValueError):validate(r,30)

    def test_stale_selection_even_if_audio_clock_continues(self):
        r=rows();r[3]['frameAgeUs']=100001
        with self.assertRaises(ValueError):validate(r,30)
    def test_short_is_not_long(self):
        self.assertEqual(validate(rows(),30)['durationSeconds'],30)
        with self.assertRaises(ValueError):validate(rows(),1200)

    def test_rejects_stall_fallback_frame_gap_and_missing_clocks(self):
        for key,value in [('audioUs',None),('positionUs',0),('candidate',False),('nativePlaying',False),
                          ('videoFrames',0),('maxLagUs',100001),('orderErrors',1),('dropped',1),
                          ('rendererCount',2),('pid',43),('failures',['error'])]:
            r=rows();r[3][key]=value
            with self.subTest(key=key),self.assertRaises(ValueError):validate(r,30)

    def test_rejects_missing_or_unreleased_disposal(self):
        for change in [lambda r:r.pop(),lambda r:r[-1].update(ledgerBytes=1),lambda r:r[-1].update(pending=True)]:
            r=rows();change(r)
            with self.assertRaises(ValueError):validate(r,30)

    def test_long_validates_duration_and_cadence(self):
        r=rows();ticks=[]
        for i in range(241):
            t=copy.deepcopy(r[0]);t.update(uptime=10+5*i,audioUs=2000000+5000000*i,positionUs=2000000+5000000*i,
                videoPTS=1990000+5000000*i,videoFrames=48+120*i,published=48+120*i);ticks.append(t)
            t['modes'].update(renderedSubmissions=100+235*i,renderedCallbacks=80+235*i)
        r[-2]['uptime']=1211;r[-1]['uptime']=1213
        self.assertEqual(validate(ticks+r[-2:],1200)['durationSeconds'],1200)
        ticks[10]['uptime']+=3
        with self.assertRaises(ValueError):validate(ticks+r[-2:],1200)

if __name__=='__main__':unittest.main()
