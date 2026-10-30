from pathlib import Path
p=Path('tool/playback_network/test_budget_exhaustion.py');s=p.read_text().replace("credentialCommitAccepted=True)","credentialCommitAccepted=True,ticketIntentRevision=4,ticketCredentialRevision=0)",1).replace("dict(elapsed=t,reason='budgetExhausted'","dict(elapsed=t,sessionId='same',reason='budgetExhausted'",1)
s+='''
    def test_rejects_wrong_session_or_authority_changes_even_with_later_complete_windows(self):
        for field in ['sessionId','generation','intentRevision','credentialRevision']:
            rows,frames,decisions=copy.deepcopy(evidence())
            if field=='sessionId':
                for d in decisions:d['sessionId']='unrelated'
            else:
                early=dict(decisions[0],elapsed=49)
                early[field]=early[field]-1 if field!='credentialRevision' else 0
                if field=='credentialRevision':
                    for d in decisions:d[field]=1
                decisions.insert(0,early)
            with self.subTest(field=field),self.assertRaises(ValueError):summarize_budget_exhaustion(rows,frames,decisions)
''';p.write_text(s)
p=Path('tool/playback_network/test_bandwidth_diagnostics.py');s=p.read_text();s+='''

class VersionThreeCLITests(unittest.TestCase):
    def test_cli_keeps_v3_proxy_metrics_and_rejects_incomplete_transactions(self):
        import json,subprocess,sys,tempfile
        from pathlib import Path
        from test_proxy_boundaries import ProxyBoundaryTests
        from test_transaction_metrics import DurationStateTests
        fixture=BandwidthDiagnosticsTests();fixture.setUp()
        boundary=ProxyBoundaryTests();boundary.setUp()
        server=fixture.row(7,0,100,size=4096,asset='network-period-0/chunk-0-00001.m4s')
        proxy=dict(boundary.trace,version=3,metrics=DurationStateTests().source())
        policy=dict(elapsed=1,generation=0,allowed=True,width=640,position=1,remaining=119,bufferAhead=10,bytes=0,
            transfer=0,requests=0,overdue=0,reason='highOutput',attempts=0,qualifiedWindows=0,sawHigh=True,
            windowBitrate=None,windowRequests=None,pendingDue=None)
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);profiles=root/'profiles.json'
            profiles.write_text(json.dumps(dict(schemaVersion=1,profiles=[dict(id=fixture.profile.id,steps=fixture.profile.steps)])))
            for name,rows in [('requests',[server]),('policy-decisions',[policy]),('rows',[dict(proxyRequestSamplingVersion=3)])]:
                (root/(name+'.jsonl')).write_text(''.join(json.dumps(v)+'\\n' for v in rows))
            path=root/'proxy-requests.jsonl';path.write_text(json.dumps(proxy)+'\\n')
            cmd=[sys.executable,str(Path(__file__).with_name('bandwidth_diagnostics.py')),str(root),'--profiles',str(profiles)]
            result=subprocess.run(cmd,capture_output=True,text=True);self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout)['proxy']['version'],3)
            first=proxy['metrics']['transactions'][0]
            for k,state in [('fetchSeconds',2),('responseWaitSeconds',2),('responseSeconds',3)]:first[k]=None;first['durationStates'][k]=state
            path.write_text(json.dumps(proxy)+'\\n');result=subprocess.run(cmd,capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
''';p.write_text(s)
