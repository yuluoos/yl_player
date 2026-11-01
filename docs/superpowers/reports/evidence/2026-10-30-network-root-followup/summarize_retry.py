"""Extract the exact successful task's failed first transaction, without inferring VPN causality."""
import json
from pathlib import Path
import sys
run=Path(sys.argv[1])
rows=lambda name:[json.loads(l) for l in (run/name).read_text().splitlines()]
links=json.loads((run/'task-log-attribution.json').read_text())['requests']
identity=next(r for r in links if r['foundationTaskID']=='<96565444-eab1-422f-85c1-0aa3e053a4e7>.<4>')
same=lambda r:r['proxyID']==identity['proxyID'] and r['requestID']==identity['requestID']
side=next(r for r in rows('transaction-connections.jsonl') if same(r))
logs=rows('client-network.jsonl');packets=json.loads((run/'packet-summary.json').read_text())
server=json.loads((run/'connection-lifecycle.json').read_text())
result=dict(identity=identity,sidecar=side,boundary=next(r for r in rows('proxy-requests.jsonl') if same(r)),
    clientLogs=[dict(index=i,**logs[i]) for i in sorted(set(identity['taskLogIndices']+identity['connectionLogIndices']))],
    transactions=[dict(index=t['index'],flows=[dict(flowIndex=i,**f) for i,f in enumerate(packets['flows']) if f['connectionToken']==t['connectionToken']],
        serverAccepted=[c for c in server['connections'] if c['connectionToken']==t['connectionToken']]) for t in side['transactions']],
    packetCaptureSHA256=packets['captureSHA256'],
    retryTriggerObserved='CFNetwork reports ECONNRESET and reason(7) retry for the same exact task; first HTTP trace header is present in Mac capture but not accepted by the server',
    synCookieRaceProven=False,nextinCauseProven=False,
    interpretation='Two different server initial sequence numbers and an RST matching the earlier handshake are observed. Public XNU SYN-cookie code plus queue counters support a mechanism hypothesis; the emitting kernel branch is not traced. No attribution to Nextin or historical request identities is made.')
(run/'retry-chain.json').write_text(json.dumps(result,indent=2)+'\n')
print('Saved two-transaction packet/log chain')
