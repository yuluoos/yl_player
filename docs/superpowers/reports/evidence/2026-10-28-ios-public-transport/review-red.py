from pathlib import Path
p=Path('tool/playback_network/test_abr_accesslog.py');s=p.read_text().replace('publicCommandIntentBefore=0, publicCommandIntentAfter=1, publicCommandPositionBefore=19,','publicCommandIntentBefore=0, publicCommandIntentAfter=1, ticketIntentRevision=0, publicCommandPositionBefore=19,').replace("width=0 if paused else 640, position=position))","width=0 if paused else 640, position=position, framePresentationTimes=[] if paused else [position]))").replace("policy=dict(attempts=1,reservations=1,tickets=1,triggerExercised=True)","policy=dict(attempts=1,reservations=1,tickets=1,triggerExercised=True, ticketAuthorities=[dict(attempt=1,elapsed=25,intentRevision=0)], intentSamples=[dict(elapsed=0,intentRevision=0),dict(elapsed=26,intentRevision=1)])").replace("'missing-frames','wrong-effect']:","'missing-frames','wrong-effect','revision-rollback','revision-before','revision-after','ticket-revision','policy-revision','missing-pts','stale-pts','extra-pts']:").replace("elif scenario.startswith('pause'):rr[2]['position']=22", """elif mutation=='revision-rollback':rr[2]['publicIntentRevision']=999
                elif mutation=='revision-before':rr[0]['publicIntentRevision']=999
                elif mutation=='revision-after':rr[-1]['publicIntentRevision']=2
                elif mutation=='ticket-revision':e['ticketIntentRevision']=1
                elif mutation=='policy-revision':pp['ticketAuthorities'][0]['intentRevision']=1
                elif mutation in ('missing-pts','stale-pts','extra-pts'):
                    if scenario.startswith('pause'):continue
                    if mutation=='missing-pts':ff[-1].pop('framePresentationTimes')
                    elif mutation=='stale-pts':ff[-1]['framePresentationTimes']=[19]
                    else:ff[-1]['framePresentationTimes'].append(22)
                elif scenario.startswith('pause'):rr[2]['position']=22""")
p.write_text(s)
p=Path('tool/playback_network/test_abr_policy.py');s=p.read_text();marker='    def test_valid_rejections_preserve_invalid_inputs(self):'
s=s.replace(marker,'''    def test_intent_revision_rejects_cross_revision_windows_and_tickets(self):
        start = dict(row(1, 'windowStarted'), bytes=200000, transfer=1, requests=4, windowBitrate=None, windowRequests=None, intentRevision=0)
        first = dict(row(9, 'firstQualifiedWindow'), bytes=1800000, transfer=9, requests=36, windowBitrate=1600000, qualifiedWindows=1, intentRevision=0)
        reserved = dict(row(17, 'reserved', 1), bytes=3400000, transfer=17, requests=68, windowBitrate=1600000, pendingDue=17.5, intentRevision=0)
        ticket = dict(row(17.5, 'ticketReady', 1), windowBitrate=None, windowRequests=None, intentRevision=0)
        self.summary([start,first,reserved,ticket],1)
        for index,value in [(0,1),(1,1),(2,1),(3,1),(0,True),(0,-1),(0,2**64),(0,None)]:
            trace=[start,first,reserved,ticket];trace[index]=dict(trace[index],intentRevision=value)
            with self.subTest(index=index,value=value),self.assertRaises(ValueError):self.summary(trace,1)
        with self.assertRaises(ValueError):self.summary([start,dict(first,**{}) | {} if False else {k:v for k,v in first.items() if k!='intentRevision'},reserved,ticket],1)
        restarted=dict(first,reason='windowStarted',qualifiedWindows=0,windowBitrate=None,windowRequests=None,intentRevision=1)
        self.summary([start,restarted])

'''+marker);s=s.replace("dict(first,**{}) | {} if False else ","");p.write_text(s)
