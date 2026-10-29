from pathlib import Path
p=Path('tool/playback_network/test_abr_accesslog.py');s=p.read_text();at=s.index('    def test_production_pause_')
s=s[:at]+'''    def test_prepared_pause_requires_native_paused_rows_and_keeps_budget(self):
        first=dict(attempt=1,outcome='cancelled',elapsed=17.5,elapsedAfter=17.52,preparationDeadline=19.5)
        second=dict(attempt=2,outcome='installed',elapsed=36,elapsedAfter=36.1)
        e=dict(sessionId='same',scenario='pause-prepared',candidatePrepared=17.51,commandStarted=17.52,
            commandCompleted=17.53,released=17.54,tokenCancelled=True,itemUnchanged=True,attemptsAtCommand=1,
            oldEvents=[first],pauseAcknowledged=True,resumed=True,itemUnchangedBeforeResume=True,
            pausePosition=16,beforeResumePosition=16,beforeResumeAttempts=1,resumeCompleted=19.6)
        rows=[dict(elapsed=t,sessionId='same',productionCommand='pause-prepared',productionCommandEvents=e,
            automaticAttempts=1 if t<36 else 2,automaticEvents=[first] if t<36 else [first,second],
            publicPlaybackIntent=False,rate=0,hostStatus='paused',position=16) for t in [17.7,18,18.5,19,120]]
        frames=[dict(elapsed=20,frames=1,width=320,position=16),dict(elapsed=120,frames=1,width=640,position=119)]
        policy=dict(attempts=2,reservations=2,tickets=2,ticketAuthorities=[dict(attempt=1),dict(attempt=2)])
        self.assertTrue(abr_accesslog.summarize_production_race(rows,frames,policy)['secondAttemptInstalled'])
        for mutation in ['refund','moving','intent','early-resume','missing-pause']:
            rr=copy.deepcopy(rows)
            if mutation=='refund':rr[1]['automaticAttempts']=0
            elif mutation=='moving':rr[1]['position']=16.051
            elif mutation=='intent':rr[1]['publicPlaybackIntent']=True
            elif mutation=='early-resume':rr[-1]['productionCommandEvents']['resumeCompleted']=19.52
            else:rr=rr[-1:]
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):abr_accesslog.summarize_production_race(rr,frames,policy)

    def test_prepared_load_requires_one_committed_session_boundary_and_new_budget(self):
        first=dict(attempt=1,outcome='cancelled',elapsed=17.5,elapsedAfter=17.52,preparationDeadline=19.5)
        e=dict(sessionId='old',newSessionId='new',scenario='load-prepared',candidatePrepared=17.51,
            commandStarted=17.52,commandCompleted=18,released=18.01,tokenCancelled=True,itemUnchanged=False,
            attemptsAtCommand=1,positionBefore=16,targetMs=17000,oldEvents=[first])
        rows=[dict(elapsed=t,sessionId=session,productionRecovery=True,productionCommand='load-prepared',productionCommandEvents=e,
            automaticAttempts=1 if session=='old' else 0,automaticEvents=[first] if session=='old' else []) for t,session in [(17.51,'old'),(18.1,'new'),(120,'new')]]
        frames=[dict(elapsed=18.2,frames=1,width=320,position=17,framePresentationTimes=[17]),
            dict(elapsed=120,frames=1,width=640,position=119,framePresentationTimes=[119])]
        policy=dict(sessions={'old':dict(attempts=1,reservations=1,tickets=1),'new':dict(attempts=0,reservations=0,tickets=0)})
        result=abr_accesslog.summarize_production_race(rows,frames,policy)
        self.assertTrue(result['newLoad']);self.assertFalse(result['secondAttemptInstalled'])
        for mutation in ['same-session','revert','old-installed','wrong-budget','unknown-policy','old-frame']:
            rr,ff,pp=copy.deepcopy((rows,frames,policy))
            if mutation=='same-session':rr[-1]['productionCommandEvents']['newSessionId']='old'
            elif mutation=='revert':rr[-1]['sessionId']='old'
            elif mutation=='old-installed':rr[-1]['productionCommandEvents']['oldEvents'][0]['outcome']='installed'
            elif mutation=='wrong-budget':rr[-1]['automaticAttempts']=1
            elif mutation=='unknown-policy':pp['sessions']['other']=pp['sessions'].pop('new')
            else:ff[0]['framePresentationTimes']=[16.9]
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):abr_accesslog.summarize_production_race(rr,ff,pp)

''' + s[at:];p.write_text(s)
