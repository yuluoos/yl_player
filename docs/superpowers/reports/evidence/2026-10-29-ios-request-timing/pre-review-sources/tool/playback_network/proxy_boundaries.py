"""Validate opt-in request boundaries; never infer display or ABR acceptance."""
import math
import re


def proxy_trace_version(rows):
    if not any(isinstance(row, dict) and 'proxyRequestSamplingVersion' in row for row in rows):
        return None
    if not all(isinstance(row, dict) and type(row.get('proxyRequestSamplingVersion')) is int and
               row['proxyRequestSamplingVersion'] == 1 for row in rows):
        raise ValueError('unsupported or inconsistent proxy request sampling version')
    return 1


def summarize_proxy_boundaries(rows, server_rows):
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
    optional = times | {'httpStatus', 'serverRequestID'}
    require(isinstance(rows, list) and 0 < len(rows) <= 10000)
    require(isinstance(server_rows, list) and 0 < len(server_rows) <= 10000)
    servers = {}
    for server in server_rows:
        require(isinstance(server, dict))
        ident = server.get('requestId')
        require(type(ident) is int and ident > 0 and ident not in servers)
        servers[ident] = server
    identities = set(); matched = set(); results = []; counts = {}
    outcomes = ['complete', 'cancelled', 'sendFailed', 'upstreamFailed']
    for row in rows:
        require(isinstance(row, dict) and required <= row.keys() and not row.keys()-required-optional)
        require(type(row['version']) is int and row['version'] == 1)
        require(isinstance(row['proxyID'], str) and re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', row['proxyID']))
        require(all(finite(value) for key,value in row.items() if key != 'proxyID'))
        counters = required - {'version', 'proxyID', 'admission', 'terminal', 'sendWaitSum', 'sendWaitMax'}
        require(all(integer(row[key]) for key in counters) and row['requestID'] > 0)
        require(row['outcome'] in range(4))
        identity = (row['proxyID'], row['requestID'])
        require(identity not in identities); identities.add(identity)
        require(row['terminal'] >= row['admission'])
        for key in times & row.keys():
            require(row['admission'] <= row[key] <= row['terminal'])
        for before,after in [('response','firstBody'),('firstBody','lastBody'),
            ('lastBody','upstreamComplete'),('firstSend','lastSend'),('lastSend','lastSendComplete')]:
            if before in row and after in row: require(row[before] <= row[after])
        require(row['sentBodyBytes'] <= row['bodyBytes'] and row['sendFailures'] <= row['sendCompletions'] <= row['sendCount'])
        require(row['sendWaitMax'] <= row['sendWaitSum'] + 1e-9)
        if row['bodyBytes']:
            require({'firstBody','lastBody'} <= row.keys() and row['bodyCallbacks'] > 0)
        server_id = row.get('serverRequestID'); server = None
        if server_id is not None:
            require(integer(server_id) and server_id > 0 and server_id in servers and server_id not in matched)
            matched.add(server_id); server = servers[server_id]
            require(integer(row.get('httpStatus')) and row['httpStatus'] == server.get('status'))
            require(finite(server.get('startMs')) and finite(server.get('endMs')) and server['endMs'] >= server['startMs'])
            require(type(server.get('bodyBytesWritten')) is int and server['bodyBytesWritten'] >= 0)
        if row['outcome'] == 0:
            require(server is not None and {'response','upstreamComplete','lastSendComplete'} <= row.keys())
            require(row['sendCount'] > 0 and row['sendCount'] == row['sendCompletions'] and row['sendFailures'] == 0)
            require(row['bodyBytes'] == row['sentBodyBytes'] == server['bodyBytesWritten'])
            require(server.get('outcome') == 'complete' and 200 <= row['httpStatus'] < 300)
        outcome = outcomes[int(row['outcome'])]; counts[outcome] = counts.get(outcome,0)+1
        upstream = row['upstreamComplete']-row['admission'] if 'upstreamComplete' in row else None
        duration = (server['endMs']-server['startMs'])/1000 if server is not None else None
        results.append(dict(proxyID=row['proxyID'], requestID=row['requestID'], serverRequestID=server_id,
            outcome=outcome, bodyBytes=row['bodyBytes'], sentBodyBytes=row['sentBodyBytes'],
            upstreamSeconds=upstream, serverSeconds=duration,
            upstreamMinusServerSeconds=upstream-duration if upstream is not None and duration is not None else None,
            responseWaitSeconds=row['response']-row['admission'] if 'response' in row else None,
            bodyCallbackSpanSeconds=row['lastBody']-row['firstBody'] if 'lastBody' in row else None,
            sendWaitSumSeconds=row['sendWaitSum'], sendWaitMaxSeconds=row['sendWaitMax'],
            terminalSeconds=row['terminal']-row['admission']))
    media = {ident for ident, row in servers.items() if row.get('method') == 'GET' and
             isinstance(row.get('asset'),str) and row['asset'].endswith('.m4s')}
    missing = sorted(media-matched)
    return dict(version=1, requestCount=len(rows), outcomeCounts=counts, requests=results,
        unmatchedServerRequestIDs=missing, uncorrelatedProxyRequests=sum(x['serverRequestID'] is None for x in results),
        fullyCorrelated=not missing and all(x['serverRequestID'] is not None for x in results),
        interpretation='Same-device callback times; correlated server durations use their own clock. Upstream minus server includes transport, scheduling and backpressure, not isolated RTT. Send wait sums may overlap; contentProcessed is not client receipt or display.',
        physicalOutputVerified=False, capabilityAccepted=False)
