"""Validate opt-in request boundaries; never infer display or ABR acceptance."""
import math
import re
from transaction_metrics import summarize_transactions


def proxy_trace_version(rows):
    if not any(isinstance(row, dict) and 'proxyRequestSamplingVersion' in row for row in rows):
        return None
    if not all(isinstance(row, dict) and type(row.get('proxyRequestSamplingVersion')) is int and
               row['proxyRequestSamplingVersion'] in (1, 2, 3) for row in rows) or len({row['proxyRequestSamplingVersion'] for row in rows}) != 1:
        raise ValueError('unsupported or inconsistent proxy request sampling version')
    return rows[0]['proxyRequestSamplingVersion']


def summarize_proxy_boundaries(rows, server_rows, expected_version=None):
    def require(value):
        if not value:
            raise ValueError('invalid proxy request boundary evidence')

    def finite(value):
        return type(value) in (int, float) and math.isfinite(value) and value >= 0

    def integer(value):
        return finite(value) and int(value) == value

    required = {'version', 'proxyID', 'requestID', 'admission', 'terminal', 'outcome',
        'bodyBytes', 'sentBodyBytes', 'bodyCallbacks', 'sendCount', 'sendCompletions',
        'sendFailures', 'sendWaitSum', 'sendWaitMax'}
    times = {'response', 'firstBody', 'lastBody', 'firstSend', 'lastSend',
        'lastSendComplete', 'upstreamComplete'}
    optional = times | {'httpStatus', 'serverRequestID', 'correlationID', 'metrics'}
    uuid_pattern = r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}'
    def uuid(value):
        return isinstance(value, str) and re.fullmatch(uuid_pattern, value)
    require(isinstance(rows, list) and 0 < len(rows) <= 10000)
    require(isinstance(server_rows, list) and 0 < len(server_rows) <= 10000)
    servers = {}; trace_ids = {}
    for server in server_rows:
        require(isinstance(server, dict))
        ident = server.get('requestId')
        require(type(ident) is int and ident > 0 and ident not in servers)
        servers[ident] = server
        if 'proxyTraceID' in server:
            token = server['proxyTraceID']; require(uuid(token))
            require(token.lower() not in trace_ids)
            trace_ids[token.lower()] = ident
    versions = {row.get('version') for row in rows if isinstance(row, dict)}
    require(len(versions) == 1 and (expected_version is None or versions == {expected_version}))
    version = next(iter(versions))
    identities = set(); matched = set(); results = []; counts = {}
    outcomes = ['complete', 'cancelled', 'sendFailed', 'upstreamFailed']
    for row in rows:
        require(isinstance(row, dict) and required <= row.keys() and not row.keys()-required-optional)
        require(type(row['version']) is int and row['version'] in (1, 2, 3))
        require(('metrics' in row) == (row['version'] >= 2))
        require(isinstance(row['proxyID'], str) and re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', row['proxyID']))
        require(all(finite(value) for key,value in row.items() if key not in ('proxyID', 'correlationID', 'metrics')))
        counters = required - {'version', 'proxyID', 'admission', 'terminal', 'sendWaitSum', 'sendWaitMax'}
        require(all(integer(row[key]) for key in counters) and row['requestID'] > 0)
        require(row['outcome'] in range(4))
        identity = (row['proxyID'], row['requestID'])
        require(identity not in identities); identities.add(identity)
        require(row['terminal'] >= row['admission'])
        for key in times & row.keys():
            require(row['admission'] <= row[key] <= row['terminal'])
        for before,after in [('response','firstBody'),('firstBody','lastBody'),
            ('lastBody','upstreamComplete'),('firstSend','lastSend')]:
            if before in row and after in row: require(row[before] <= row[after])
        require(row['sentBodyBytes'] <= row['bodyBytes'] and row['sendFailures'] <= row['sendCompletions'] <= row['sendCount'])
        if row['sendCount'] == row['sendCompletions'] and 'lastSend' in row and 'lastSendComplete' in row:
            require(row['lastSend'] <= row['lastSendComplete'])
        require(row['sendWaitMax'] <= row['sendWaitSum'] + 1e-9)
        if row['bodyBytes']:
            require({'firstBody','lastBody'} <= row.keys() and row['bodyCallbacks'] > 0)
        server_id = row.get('serverRequestID'); server = None
        token = row.get('correlationID')
        if token is not None:
            require(uuid(token))
            linked = trace_ids.get(token.lower())
            if linked is not None:
                require(server_id is None or server_id == linked)
                server_id = linked
        if server_id is not None:
            require(integer(server_id) and server_id > 0 and server_id in servers and server_id not in matched)
            matched.add(server_id); server = servers[server_id]
            if 'response' in row or 'httpStatus' in row:
                require(integer(row.get('httpStatus')) and row['httpStatus'] == server.get('status'))
            if token is not None and 'proxyTraceID' in server:
                require(token.lower() == server['proxyTraceID'].lower())
            require(finite(server.get('startMs')) and finite(server.get('endMs')) and server['endMs'] >= server['startMs'])
            require(type(server.get('bodyBytesWritten')) is int and server['bodyBytesWritten'] >= 0)
        if row['outcome'] == 0:
            require(server is not None and {'response','upstreamComplete','lastSendComplete'} <= row.keys())
            require(row['sendCount'] > 0 and row['sendCount'] == row['sendCompletions'] and row['sendFailures'] == 0)
            require(row['bodyBytes'] == row['sentBodyBytes'] == server['bodyBytesWritten'])
            require(server.get('outcome') == 'complete' and 200 <= row['httpStatus'] < 300)
        transaction_metrics = summarize_transactions(row.get('metrics'))
        if row['version']==3 and row.get('metrics') is not None:
            require(transaction_metrics.get('version')==2)
        if row['version'] >= 2 and row['outcome'] == 0:
            require(transaction_metrics['complete'])
        outcome = outcomes[int(row['outcome'])]; counts[outcome] = counts.get(outcome,0)+1
        upstream = row['upstreamComplete']-row['admission'] if 'upstreamComplete' in row else None
        duration = (server['endMs']-server['startMs'])/1000 if server is not None else None
        results.append(dict(proxyID=row['proxyID'], requestID=row['requestID'], serverRequestID=server_id,
            outcome=outcome, transactionMetrics=transaction_metrics, bodyBytes=row['bodyBytes'], sentBodyBytes=row['sentBodyBytes'],
            upstreamSeconds=upstream, serverSeconds=duration,
            upstreamMinusServerSeconds=upstream-duration if upstream is not None and duration is not None else None,
            responseWaitSeconds=row['response']-row['admission'] if 'response' in row else None,
            bodyCallbackSpanSeconds=row['lastBody']-row['firstBody'] if 'lastBody' in row else None,
            sendWaitSumSeconds=row['sendWaitSum'], sendWaitMaxSeconds=row['sendWaitMax'],
            terminalSeconds=row['terminal']-row['admission']))
    media = {ident for ident, row in servers.items() if row.get('method') == 'GET' and
             isinstance(row.get('asset'),str) and row['asset'].endswith('.m4s')}
    missing = sorted(media-matched)
    return dict(version=version, requestCount=len(rows), outcomeCounts=counts, requests=results,
        unmatchedServerRequestIDs=missing, uncorrelatedProxyRequests=sum(x['serverRequestID'] is None for x in results),
        fullyCorrelated=not missing and all(x['serverRequestID'] is not None for x in results),
        interpretation='Same-device callback times; correlated server durations use their own clock. Upstream minus server includes transport, scheduling and backpressure, not isolated RTT. Send wait sums may overlap; contentProcessed is not client receipt or display.',
        physicalOutputVerified=False, capabilityAccepted=False)


def record_proxy_observation(receipt, rows, server_rows, expected_version=None):
    observation = summarize_proxy_boundaries(rows, server_rows, expected_version)
    receipt['proxyRequestObservation'] = observation
    if not observation['fullyCorrelated']:
        receipt['errors'].append('proxy request correlation incomplete')
