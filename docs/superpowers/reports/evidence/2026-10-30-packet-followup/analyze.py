import json
from pathlib import Path

root=Path(__file__).parent
run=root/'media'
receipt=json.loads((run/'receipt.json').read_text())
packets=json.loads((run/'packet-summary.json').read_text())
boundaries=[json.loads(line) for line in (run/'proxy-requests.jsonl').read_text().splitlines()]
links=receipt['transactionConnectionObservation']['requests']
attributions=receipt['packetAttributionObservation']['requests']
lifecycle=json.loads((run/'connection-lifecycle.json').read_text())
def identity(row):return row['proxyID'].lower(),row['requestID']
raw={identity(row):row for row in boundaries}
attached={identity(row):row for row in attributions}
accepted={row['connectionToken']:row for row in lifecycle['connections']}
suspects=[]
for row in links:
    boundary=raw[identity(row)]
    if (len(row['transactions'])!=1 or boundary['outcome']!=0 or
        any(t['binding']!='bound' or not t['responsePresent'] for t in row['transactions'])):
        attribution=attached[identity(row)]
        indices=set(attribution['correlationFlowIndices'])
        for transaction in attribution['transactions']:indices.update(transaction['flowIndices'])
        suspects.append(dict(boundary=boundary,connections=row,attribution=attribution,
            flows=[dict(flowIndex=i,flow=packets['flows'][i],
                acceptedConnection=accepted.get(packets['flows'][i]['connectionToken'])) for i in sorted(indices)]))
result=dict(capture=receipt['packetCaptureObservation'],passed=receipt['passed'],errors=receipt['errors'],
    packetCount=packets['packetCount'],flowCount=len(packets['flows']),taskCount=len(links),
    packetObservedTasks=sum(row['packetObserved'] is True for row in attributions),
    suspectRequests=suspects,
    flowsWithoutServerAccept=[dict(flowIndex=i,flow=f) for i,f in enumerate(packets['flows']) if f['connectionToken'] not in accepted],
    rootCauseEstablished=False,physicalDeliveryProven=False)
(root/'diagnosis.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items() if k not in ('suspectRequests','flowsWithoutServerAccept')},indent=2))
print('suspects',len(suspects),'unaccepted flows',len(result['flowsWithoutServerAccept']))
for row in suspects:
    b=row['boundary']
    print(json.dumps(dict(proxyID=b['proxyID'],requestID=b['requestID'],outcome=b['outcome'],
        cancelCause=b['cancelCause'],connections=row['connections']['transactions'],
        packetAttribution=row['attribution']),indent=2))
