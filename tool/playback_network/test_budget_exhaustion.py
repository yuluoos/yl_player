import copy
import unittest
try:
    from budget_exhaustion import summarize_budget_exhaustion
except ImportError:
    summarize_budget_exhaustion=None


def evidence():
    event=dict(attempt=2,outcome='installed',elapsedAfter=30,itemChanged=True,credentialCommitAccepted=True,ticketIntentRevision=4,ticketCredentialRevision=0)
    rows=[dict(elapsed=t,sessionId='same',productionRecovery=True,captureDeviceKind='physical',policySamplingVersion=2,
               automaticAttempts=2,automaticEvents=[event],hostFailureCount=0) for t in [31,70,120]]
    frames=[dict(elapsed=t,frames=1,width=w,generation=1,position=t) for t,w in [(31,640),(49,320),(50,320),(58,320),(66,320)]]
    decisions=[dict(elapsed=t,sessionId='same',reason='budgetExhausted',attempts=2,generation=2,intentRevision=4,credentialRevision=0,allowed=True,sawHigh=True,width=320,
        overdue=1,position=t,remaining=120-t,bufferAhead=10,bytes=int((t-50)*200000),transfer=t-50,requests=int((t-50)*4),pendingDue=None) for t in [50,58,66,70]]
    return rows,frames,decisions


class BudgetExhaustionTests(unittest.TestCase):
    def setUp(self):self.assertIsNotNone(summarize_budget_exhaustion)
    def test_requires_real_second_install_new_low_frames_and_two_qualified_windows(self):
        result=summarize_budget_exhaustion(*evidence())
        self.assertEqual(len(result['qualifiedCounterfactualWindows']),2)
        self.assertEqual(result['maximumAttempts'],2)
        self.assertFalse(result['capabilityAccepted']);self.assertFalse(result['continuityAccepted'])

    def test_rejects_old_low_history_third_attempt_or_insufficient_current_conditions(self):
        for mutation in ['no-install','first-attempt','no-high-after','no-low-after','changed-item','source','third-attempt','third-event','not-allowed','not-low','buffer','remaining','overdue','weak','few-requests','short','no-progress','interrupted','counter-regression','intent-change','gap','wrong-policy']:
            rows,frames,decisions=copy.deepcopy(evidence())
            if mutation=='no-install':rows[-1]['automaticEvents']=[]
            elif mutation=='first-attempt':rows[-1]['automaticEvents'][0]['attempt']=1
            elif mutation=='no-high-after':frames[0]['elapsed']=29
            elif mutation=='no-low-after':frames=frames[:1]
            elif mutation=='changed-item':frames[1]['generation']=2
            elif mutation=='source':rows[-1]['sessionId']='new'
            elif mutation=='third-attempt':rows[-1]['automaticAttempts']=3
            elif mutation=='third-event':rows[-1]['automaticEvents'].append(dict(attempt=3,outcome='cancelled'))
            elif mutation=='not-allowed':decisions[1]['allowed']=False
            elif mutation=='not-low':decisions[1]['width']=640
            elif mutation=='buffer':decisions[1]['bufferAhead']=4.99
            elif mutation=='remaining':decisions[1]['remaining']=19.99
            elif mutation=='overdue':decisions[1]['overdue']=0
            elif mutation=='weak':
                for d in decisions:d['bytes']=int((d['elapsed']-50)*100000)
            elif mutation=='few-requests':
                for d in decisions:d['requests']=int((d['elapsed']-50)/8)
            elif mutation=='short':decisions=decisions[:2]
            elif mutation=='no-progress':
                for d in decisions:d['position']=50
            elif mutation=='interrupted':decisions[1]['reason']='highOutput'
            elif mutation=='counter-regression':decisions[2]['transfer']=0
            elif mutation=='intent-change':decisions[1]['intentRevision']=5
            elif mutation=='gap':decisions[1]['elapsed']=65
            else:rows[0]['policySamplingVersion']=1
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):summarize_budget_exhaustion(rows,frames,decisions)

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
