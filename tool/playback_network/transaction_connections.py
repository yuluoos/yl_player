"""Opt-in opaque endpoint evidence; never infer unsent bytes or retry causes."""
import argparse
import hashlib
import hmac
import ipaddress
import json
from pathlib import Path
import re
import struct


def connection_token(key, client, server):
    payload = (b'yl-connection-v1\n' + ipaddress.IPv4Address(client[0]).packed + struct.pack('!H',client[1]) +
               ipaddress.IPv4Address(server[0]).packed + struct.pack('!H',server[1]))
    return hmac.new(key,payload,hashlib.sha256).hexdigest()


def summarize_connections(sidecar, boundaries, observation, lifecycle, lifecycle_observation):
    """Reuse already validated main metrics and lifecycle, without rerunning gates."""
    def require(value):
        if not value:raise ValueError('invalid transaction connection evidence')
    def identity(row):return row['proxyID'].lower(),row['requestID']
    require(observation is not None and lifecycle_observation is not None and lifecycle['version']==2)
    validated={identity(row):row for row in observation['requests']}
    main={identity(row):row for row in boundaries}
    require(main.keys()==validated.keys() and len(main)==len(boundaries))
    require(isinstance(sidecar,list) and len(sidecar)<=len(main))
    attached={}
    for row in sidecar:
        require(isinstance(row,dict) and set(row)=={'version','proxyID','requestID','correlationID','transactions'} |
                ({'foundationTaskID'} if row.get('version')==3 else set()))
        require(type(row['version']) is int and row['version'] in (1,2,3) and isinstance(row['proxyID'],str) and
                type(row['requestID']) is int and isinstance(row['correlationID'],str))
        if row['version']==3:
            task=row['foundationTaskID']
            require(task is None or isinstance(task,str) and
                    re.fullmatch(r'<[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}>\.<[1-9][0-9]*>',task))
        require(re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',row['correlationID']))
        ident=identity(row);require(ident in main and ident not in attached)
        require(row['correlationID'].lower()==main[ident].get('correlationID','').lower())
        metrics=validated[ident]['transactionMetrics']
        require(metrics['available'])
        transactions=row['transactions'];require(isinstance(transactions,list) and len(transactions)==len(metrics['transactions']))
        for index,item in enumerate(transactions):
            require(isinstance(item,dict) and set(item)=={'index','connectionToken','proxyConnection','responsePresent'} |
                    ({'endpointFields'} if row['version']>=2 else set()))
            require(type(item['index']) is int and item['index']==index)
            require(type(item['proxyConnection']) is bool and type(item['responsePresent']) is bool)
            require(item['connectionToken'] is None or isinstance(item['connectionToken'],str) and
                    re.fullmatch('[0-9a-f]{64}',item['connectionToken']))
            if row['version']>=2:
                mask=item['endpointFields']
                require(type(mask) is int and 0<=mask<=15)
                require(item['connectionToken'] is None or mask==15)
        attached[ident]=row
    tokens={}
    for row in lifecycle['connections']:tokens.setdefault(row['connectionToken'],[]).append(row['connectionId'])
    results=[];complete=lifecycle_observation['complete'] and bool(main)
    for ident,row in main.items():
        extra=attached.get(ident);transactions=[]
        availability='unknown' if extra is None else ('reported' if extra['transactions'] else 'no-transactions')
        if extra is None:complete=False
        else:
            for item in extra['transactions']:
                token=item['connectionToken'];matches=tokens.get(token,[])
                missing_endpoint=('unsupported-endpoint' if extra['version']>=2 and item['endpointFields']==15
                                  else 'endpoint-unavailable')
                binding=('proxy' if item['proxyConnection'] else missing_endpoint if token is None else
                         'ambiguous' if len(matches)>1 else 'unmatched' if not matches else 'bound')
                transactions.append(dict(item,connectionId=matches[0] if binding=='bound' else None,binding=binding))
                complete=complete and binding=='bound'
            complete=complete and not validated[ident]['transactionMetrics']['truncated']
        results.append(dict(proxyID=row['proxyID'],requestID=row['requestID'],availability=availability,transactions=transactions))
        if extra is not None and extra['version']==3:
            results[-1]['foundationTaskID']=extra['foundationTaskID']
    return dict(version=1,availability='reported',complete=bool(complete),requests=results,
        retryCauseProven=False,unsentProven=False,capabilityAccepted=False,
        interpretation='Only a unique capture-scoped endpoint token binds a transaction to an accepted connection. Missing metrics, unavailable or unsupported endpoints, proxies, unmatched and repeated tuples remain unbound; zero transactions never proves no packets.')


def record_connections(receipt, sidecar, boundaries, observation, lifecycle, lifecycle_observation):
    try:
        result=summarize_connections(sidecar,boundaries,observation,lifecycle,lifecycle_observation)
    except (ValueError,KeyError,TypeError):
        result=dict(version=1,availability='unknown' if not sidecar else 'invalid',complete=False,
                    requests=[],retryCauseProven=False,unsentProven=False,capabilityAccepted=False)
    receipt['transactionConnectionObservation']=result
    if not result['complete']:receipt['errors'].append('transaction connection evidence incomplete')
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory',type=Path)
    args=parser.parse_args()
    from abr_accesslog import read_rows
    from proxy_boundaries import record_proxy_observation,proxy_trace_version
    from connection_lifecycle import summarize_lifecycle
    receipt={'errors':[]};directory=args.directory
    boundaries=read_rows(directory/'proxy-requests.jsonl');server=read_rows(directory/'requests.jsonl')
    record_proxy_observation(receipt,boundaries,server,proxy_trace_version(read_rows(directory/'rows.jsonl')))
    lifecycle=json.loads((directory/'connection-lifecycle.json').read_text())
    lifecycle_observation=summarize_lifecycle(lifecycle,server)
    sidecar_path=directory/'transaction-connections.jsonl'
    sidecar=read_rows(sidecar_path) if sidecar_path.exists() else []
    record_connections(receipt,sidecar,boundaries,
                       receipt.get('proxyRequestObservation'),lifecycle,lifecycle_observation)
    print(json.dumps(receipt,indent=2))
    return 0 if not receipt['errors'] else 1


if __name__=='__main__':raise SystemExit(main())
