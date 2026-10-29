from pathlib import Path
Path('tool/playback_network/transaction_metrics.py').write_text('''"""Privacy-bounded Foundation transaction durations; missing is never zero."""
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
    require(isinstance(metrics, dict) and set(metrics) ==
            {'taskSeconds', 'transactionCount', 'redirectCount', 'truncated', 'transactions'})
    require(duration(metrics['taskSeconds']))
    require(integer(metrics['transactionCount']) and integer(metrics['redirectCount']))
    count = metrics['transactionCount']
    require(integer(metrics['truncated'], 1) and metrics['truncated'] == int(count > 32))
    transactions = metrics['transactions']
    require(isinstance(transactions, list) and len(transactions) == min(count, 32))
    complete = metrics['taskSeconds'] is not None and count > 0 and not metrics['truncated']
    for item in transactions:
        require(isinstance(item, dict) and set(item) == DURATIONS | {'reused', 'protocolCode', 'fetchType'})
        require(all(duration(item[k]) for k in DURATIONS))
        require(integer(item['reused'], 1) and integer(item['protocolCode'], 3) and integer(item['fetchType'], 3))
        core_present = all(item[k] is not None for k in ('fetchSeconds',) + CORE)
        if core_present:
            require(math.isclose(item['fetchSeconds'], sum(item[k] for k in CORE), rel_tol=1e-6, abs_tol=1e-6))
        complete = complete and core_present and item['fetchType'] == 1
    return dict(copy.deepcopy(metrics), available=True, complete=bool(complete))
''')
p=Path('tool/playback_network/proxy_boundaries.py');s=p.read_text().replace('import re\n','import re\nfrom transaction_metrics import summarize_transactions\n')
s=s.replace("row['proxyRequestSamplingVersion'] == 1 for row in rows)","row['proxyRequestSamplingVersion'] in (1, 2) for row in rows) or len({row['proxyRequestSamplingVersion'] for row in rows}) != 1")
s=s.replace('    return 1\n','    return rows[0][\'proxyRequestSamplingVersion\']\n',1)
s=s.replace('def summarize_proxy_boundaries(rows, server_rows):','def summarize_proxy_boundaries(rows, server_rows, expected_version=None):')
s=s.replace("optional = times | {'httpStatus', 'serverRequestID', 'correlationID'}","optional = times | {'httpStatus', 'serverRequestID', 'correlationID', 'metrics'}")
s=s.replace("    identities = set();", "    versions = {row.get('version') for row in rows if isinstance(row, dict)}\n    require(len(versions) == 1 and (expected_version is None or versions == {expected_version}))\n    version = next(iter(versions))\n    identities = set();")
s=s.replace("row['version'] == 1)","row['version'] in (1, 2))\n        require(('metrics' in row) == (row['version'] == 2))")
s=s.replace("('proxyID', 'correlationID')))","('proxyID', 'correlationID', 'metrics')))")
s=s.replace("        outcome = outcomes", "        transaction_metrics = summarize_transactions(row.get('metrics'))\n        if row['version'] == 2 and row['outcome'] == 0:\n            require(transaction_metrics['complete'])\n        outcome = outcomes")
s=s.replace("outcome=outcome, bodyBytes=", "outcome=outcome, transactionMetrics=transaction_metrics, bodyBytes=")
s=s.replace('return dict(version=1, requestCount=', 'return dict(version=version, requestCount=')
s=s.replace('def record_proxy_observation(receipt, rows, server_rows):\n    observation = summarize_proxy_boundaries(rows, server_rows)', 'def record_proxy_observation(receipt, rows, server_rows, expected_version=None):\n    observation = summarize_proxy_boundaries(rows, server_rows, expected_version)')
p.write_text(s)
p=Path('tool/playback_network/abr_accesslog.py');s=p.read_text().replace('if proxy_trace_version(rows) == 1 and not direct:', 'if proxy_trace_version(rows) in (1, 2) and not direct:');p.write_text(s)
p=Path('tool/playback_network/bandwidth_diagnostics.py');s=p.read_text().replace("if proxy_trace_version(read_rows(args.capture/'rows.jsonl')) == 1:","version = proxy_trace_version(read_rows(args.capture/'rows.jsonl'))\n    if version in (1, 2):").replace("read_rows(args.capture/'proxy-requests.jsonl'), requests)","read_rows(args.capture/'proxy-requests.jsonl'), requests, version)");p.write_text(s)
p=Path('tool/playback_network/test_proxy_boundaries.py');s=p.read_text().replace("[{'proxyRequestSamplingVersion':2}]","[{'proxyRequestSamplingVersion':3}]");s+='''
    def test_v2_metrics_required_and_bound_to_probe_version(self):
        from transaction_metrics import summarize_transactions
        from test_transaction_metrics import metrics
        from proxy_boundaries import proxy_trace_version
        self.assertEqual(proxy_trace_version([{'proxyRequestSamplingVersion':2}]),2)
        row=dict(self.trace,version=2,metrics=metrics())
        self.assertTrue(summarize_proxy_boundaries([row],[self.server],2)['requests'][0]['transactionMetrics']['complete'])
        for data,version in [(row,1),(dict(row,metrics=None),2),(self.trace,2)]:
            with self.assertRaises(ValueError):summarize_proxy_boundaries([data],[self.server],version)
''';p.write_text(s)
