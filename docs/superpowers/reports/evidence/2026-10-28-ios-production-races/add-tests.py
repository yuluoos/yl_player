from pathlib import Path
p=Path('tool/playback_network/test_abr_accesslog.py');s=p.read_text();at=s.index('    def test_production_pause_')
s=s[:at]+'''    def test_prepared_production_race_requires_cancelled_candidate_and_actual_pts(self):
        marker = dict(sessionId='same', scenario='seek-prepared', candidatePrepared=17.51,
            commandStarted=17.52, commandCompleted=17.53, released=17.54, tokenCancelled=True,
            itemUnchanged=True, attemptsAtCommand=1, targetMs=17000, positionBefore=16,
            oldEvents=[dict(attempt=1, outcome='cancelled', elapsed=17.5, elapsedAfter=17.52,
                            preparationDeadline=19.5)])
        first=marker['oldEvents'][0];second=dict(attempt=2,outcome='installed',elapsed=36,elapsedAfter=36.1)
        rows=[dict(elapsed=t, sessionId='same', productionCommand='seek-prepared', productionCommandEvents=marker,
                   automaticAttempts=1 if t<36 else 2,automaticEvents=[first] if t<36 else [first,second]) for t in [18,20,120]]
        frames=[dict(elapsed=18,frames=1,width=320,position=17,framePresentationTimes=[17]),
                dict(elapsed=120,frames=1,width=640,position=119,framePresentationTimes=[119])]
        policy=dict(attempts=2,reservations=2,tickets=2,ticketAuthorities=[dict(attempt=1),dict(attempt=2)])
        self.assertTrue(abr_accesslog.summarize_production_race(rows,frames,policy)['oldCandidateRejected'])
        for mutation in ['uncancelled','late','changed-item','wrong-budget','wrong-pts','missing-pts','installed-old','missing-ticket','wrong-echo']:
            rr,ff,pp=copy.deepcopy((rows,frames,policy));e=rr[-1]['productionCommandEvents']
            if mutation=='uncancelled':e['tokenCancelled']=False
            elif mutation=='late':e['released']=20
            elif mutation=='changed-item':e['itemUnchanged']=False
            elif mutation=='wrong-budget':e['attemptsAtCommand']=0
            elif mutation=='wrong-pts':ff[0]['framePresentationTimes']=[16.9]
            elif mutation=='missing-pts':ff[0]['framePresentationTimes']=[]
            elif mutation=='installed-old':e['oldEvents'][0]['outcome']='installed'
            elif mutation=='missing-ticket':pp['tickets']=1
            else:rr[0]['productionCommand']='none'
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):
                abr_accesslog.summarize_production_race(rr,ff,pp)

''' + s[at:];p.write_text(s)
