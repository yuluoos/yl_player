from pathlib import Path
p=Path('tool/playback_network/test_abr_accesslog.py');s=p.read_text();i=s.index('    def test_production_recovery_requires_physical')
s=s[:i]+'''    def test_production_pause_keeps_budget_and_requires_real_paused_samples(self):
        marker = dict(sessionId='same', pauseStarted=17, resumeCompleted=19.1, pausePosition=16,
            beforeResumePosition=16, reservationAttempts=1, beforeResumeAttempts=1,
            itemUnchangedBeforeResume=True, installedBeforeResume=False, pauseAcknowledged=True, resumed=True)
        event = dict(attempt=2, outcome='installed', elapsed=36)
        rows = [dict(elapsed=t, sessionId='same', productionCommand='pause-resume', productionCommandEvents=marker,
            automaticAttempts=1 if t<36 else 2, automaticEvents=[] if t<36 else [event],
            rate=0, publicPlaybackIntent=False, hostStatus='paused', position=16) for t in [17.2,17.6,18,18.4,19,120]]
        policy = dict(reservations=2, tickets=1, attempts=2, ticketAuthorities=[dict(attempt=2)])
        self.assertTrue(abr_accesslog.summarize_production_command(rows,policy)['cancelledReservationPreserved'])
        for mutation in ['refunded','played','drift','installed','missing-pause','wrong-ticket','wrong-echo']:
            rr, pp = copy.deepcopy((rows,policy))
            if mutation=='refunded':rr[0]['automaticAttempts']=0
            elif mutation=='played':rr[0]['publicPlaybackIntent']=True
            elif mutation=='drift':rr[0]['position']=16.051
            elif mutation=='installed':rr[-1]['productionCommandEvents']['installedBeforeResume']=True
            elif mutation=='missing-pause':rr=rr[-1:]
            elif mutation=='wrong-ticket':pp['ticketAuthorities'][0]['attempt']=1
            else:rr[0]['productionCommand']='none'
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):
                abr_accesslog.summarize_production_command(rr,pp)

'''+s[i:];p.write_text(s)
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text();i=s.index('def production_recovery');s=s[:i]+"def summarize_production_command(rows, policy):\n    return dict(cancelledReservationPreserved=False)\n\n\n"+s[i:];p.write_text(s)
