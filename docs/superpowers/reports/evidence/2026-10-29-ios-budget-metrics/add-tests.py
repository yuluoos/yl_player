from pathlib import Path
p=Path('tool/playback_network/test_transaction_metrics.py');s=p.read_text();s+='''

class DurationStateTests(unittest.TestCase):
    def source(self):
        value=metrics();value['version']=2
        value['transactions'][0]['durationStates']={k:(3 if v is None else 0) for k,v in value['transactions'][0].items() if k.endswith('Seconds')}
        return value

    def test_distinguishes_unavailable_dates_without_promoting_partial_transaction(self):
        value=self.source();self.assertTrue(summarize_transactions(value)['complete'])
        early=copy.deepcopy(value['transactions'][0])
        for field,state in [('fetchSeconds',2),('responseWaitSeconds',2),('responseSeconds',3)]:
            early[field]=None;early['durationStates'][field]=state
        value.update(transactionCount=2,transactions=[early,value['transactions'][0]])
        out=summarize_transactions(value)
        self.assertFalse(out['complete']);self.assertEqual(out['transactions'][0]['durationStates']['responseSeconds'],3)
        self.assertIsNone(out['transactions'][0]['fetchSeconds'])

    def test_rejects_missing_or_contradictory_states_and_version_downgrade(self):
        for mutation in ['missing','false-valid','false-missing','bool','unknown','extra','version','legacy-extra']:
            value=self.source();item=value['transactions'][0]
            if mutation=='missing':del item['durationStates']['fetchSeconds']
            elif mutation=='false-valid':item['durationStates']['dnsSeconds']=0
            elif mutation=='false-missing':item['durationStates']['fetchSeconds']=2
            elif mutation=='bool':item['durationStates']['fetchSeconds']=False
            elif mutation=='unknown':item['durationStates']['fetchSeconds']=5
            elif mutation=='extra':item['durationStates']['url']=0
            elif mutation=='version':value['version']=3
            else:del value['version']
            with self.subTest(mutation=mutation),self.assertRaises(ValueError):summarize_transactions(value)
''';p.write_text(s)
p=Path('tool/playback_network/test_proxy_boundaries.py');s=p.read_text().replace("[{'proxyRequestSamplingVersion':3}]","[{'proxyRequestSamplingVersion':4}]")
s+='''

class ProxyDateStateTests(unittest.TestCase):
    def test_v3_requires_date_states_and_preserves_partial_failure_gate(self):
        from proxy_boundaries import proxy_trace_version
        from test_transaction_metrics import DurationStateTests,metrics
        fixture=ProxyBoundaryTests();fixture.setUp()
        self.assertEqual(proxy_trace_version([dict(proxyRequestSamplingVersion=3)]),3)
        row=dict(fixture.trace,version=3,metrics=DurationStateTests().source())
        self.assertTrue(summarize_proxy_boundaries([row],[fixture.server],3)['requests'][0]['transactionMetrics']['complete'])
        for value in [metrics(),None]:
            with self.assertRaises(ValueError):summarize_proxy_boundaries([dict(row,metrics=value)],[fixture.server],3)
        early=copy.deepcopy(row['metrics']['transactions'][0]);early['responseSeconds']=None;early['durationStates']['responseSeconds']=2
        row['metrics'].update(transactionCount=2,transactions=[early,row['metrics']['transactions'][0]])
        with self.assertRaises(ValueError):summarize_proxy_boundaries([row],[fixture.server],3)
        row['outcome']=1
        self.assertFalse(summarize_proxy_boundaries([row],[fixture.server],3)['requests'][0]['transactionMetrics']['complete'])
''';p.write_text(s)
base=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=base.read_text();start=s.index('  func testProxyRequestTimingCorrelatesOwnedServerWithoutResourceIdentity()');end=s.index('  func testProxyBoundarySnapshotTracksRealRequest',start)
old=s[start:end];new=old.replace('testProxyRequestTimingCorrelatesOwnedServerWithoutResourceIdentity','testProxyTransactionsPreserveMissingResponseDatesAfterOwnedConnectionClose')
new=new.replace('server.handler = { _ in (200, ["X-Yl-Request-Id": "17"], Data([1, 2, 3, 4])) }','server.handler = { _ in\n      if server.requests.count == 1 { return (0, [:], Data()) }\n      return (200, ["X-Yl-Request-Id": "17"], Data([1, 2, 3, 4]))\n    }')
new=new.replace('XCTAssertEqual(transactions.count, 1)','XCTAssertEqual(transactions.count, 2)\n    XCTAssertEqual(server.requests.count, 2)\n    XCTAssertEqual(row["version"] as? Int, 3)\n    XCTAssertEqual(metrics["version"] as? Int, 2)')
new=new.replace('XCTAssertEqual(metrics["transactionCount"] as? Int, 1)','XCTAssertEqual(metrics["transactionCount"] as? Int, 2)')
new=new.replace('XCTAssertNotNil(transactions.first?["responseSeconds"] as? Double)','''let first = try XCTUnwrap(transactions.first)
    XCTAssertTrue(first["fetchSeconds"] is NSNull)
    XCTAssertTrue(first["responseWaitSeconds"] is NSNull)
    XCTAssertTrue(first["responseSeconds"] is NSNull)
    let states = try XCTUnwrap(first["durationStates"] as? [String: Int])
    XCTAssertEqual(states["fetchSeconds"], 2)
    XCTAssertEqual(states["responseWaitSeconds"], 2)
    XCTAssertEqual(states["responseSeconds"], 3)
    XCTAssertNotNil(transactions.last?["responseSeconds"] as? Double)''')
s=s[:end]+new+s[end:]
# A controlled response-less close is a fixture operation, not a production retry.
s=s.replace('let (status, extra, body) = handler?(request) ?? (404, [:], Data())','let (status, extra, body) = handler?(request) ?? (404, [:], Data())\n        if status == 0 { connection.cancel(); return }')
base.write_text(s)
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_text('@testable import yl_player_media_core\n'+s)
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("{'ios': 875, 'macos': 919}","{'ios': 876, 'macos': 920}"))
