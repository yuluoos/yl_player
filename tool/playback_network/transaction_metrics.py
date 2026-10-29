"""Privacy-bounded Foundation transaction durations; missing is never zero."""
import copy
import math

DURATIONS = {'fetchSeconds', 'fetchToRequestSeconds', 'dnsSeconds', 'connectSeconds',
             'tlsSeconds', 'requestSeconds', 'responseWaitSeconds', 'responseSeconds'}
CORE = ('fetchToRequestSeconds', 'requestSeconds', 'responseWaitSeconds', 'responseSeconds')


def summarize_transactions(metrics):
    def require(ok):
        if not ok:
            raise ValueError('invalid URLSession transaction metrics')

    def duration(value):
        return value is None or (type(value) in (int, float) and math.isfinite(value) and value >= 0)

    def integer(value, maximum=None):
        return type(value) is int and value >= 0 and (maximum is None or value <= maximum)

    if metrics is None:
        return dict(available=False, complete=False, taskSeconds=None, transactions=[])
    require(isinstance(metrics, dict))
    v2 = 'version' in metrics
    require(not v2 or (type(metrics['version']) is int and metrics['version'] in (2, 3)))
    v3 = v2 and metrics['version'] == 3
    require(set(metrics) == {'taskSeconds', 'transactionCount', 'redirectCount', 'truncated', 'transactions'} | ({'version'} if v2 else set()))
    require(duration(metrics['taskSeconds']))
    require(integer(metrics['transactionCount']) and integer(metrics['redirectCount']))
    count = metrics['transactionCount']
    # A cancelled redirect may have no following transaction yet.
    require(metrics['redirectCount'] <= count)
    require(integer(metrics['truncated'], 1) and metrics['truncated'] == int(count > 32))
    transactions = metrics['transactions']
    require(isinstance(transactions, list) and len(transactions) == min(count, 32))
    complete = metrics['taskSeconds'] is not None and count > 0 and not metrics['truncated']
    for item in transactions:
        require(isinstance(item, dict) and set(item) == DURATIONS | {'reused', 'protocolCode', 'fetchType'} | ({'durationStates'} if v2 else set()) | ({'transportBytes'} if v3 else set()))
        require(all(duration(item[k]) for k in DURATIONS))
        require(integer(item['reused'], 1) and integer(item['protocolCode'], 3) and integer(item['fetchType'], 3))
        if v3:
            counts = item['transportBytes']
            require(isinstance(counts, dict) and set(counts) ==
                    {'requestHeaders', 'requestBody', 'responseHeaders', 'responseBody'})
            require(all(value is None or integer(value, 2**63-1) for value in counts.values()))
        if v2:
            states=item['durationStates'];require(isinstance(states,dict) and set(states)==DURATIONS)
            pairs={'fetchSeconds':('fetch','responseEnd'),'fetchToRequestSeconds':('fetch','requestStart'),
                'dnsSeconds':('dnsStart','dnsEnd'),'connectSeconds':('connectStart','connectEnd'),
                'tlsSeconds':('tlsStart','tlsEnd'),'requestSeconds':('requestStart','requestEnd'),
                'responseWaitSeconds':('requestEnd','responseStart'),'responseSeconds':('responseStart','responseEnd')}
            presence={}
            for field,(start,end) in pairs.items():
                state=states[field];require(integer(state,4) and (item[field] is not None)==(state==0))
                for name,present in [(start,state not in (1,3)),(end,state not in (2,3))]:
                    require(name not in presence or presence[name]==present);presence[name]=present

        if item['fetchSeconds'] is not None and metrics['taskSeconds'] is not None:
            require(item['fetchSeconds'] <= metrics['taskSeconds'] + 1e-6)
        core_present = all(item[k] is not None for k in ('fetchSeconds',) + CORE)
        if core_present:
            require(math.isclose(item['fetchSeconds'], sum(item[k] for k in CORE), rel_tol=1e-6, abs_tol=1e-6))
        complete = complete and core_present and item['fetchType'] == 1
    return dict(copy.deepcopy(metrics), available=True, complete=bool(complete))
