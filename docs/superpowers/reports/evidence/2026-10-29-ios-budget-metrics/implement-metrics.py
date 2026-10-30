from pathlib import Path
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift');s=p.read_text().replace('values = ["version": 2, "metrics": NSNull()', 'values = ["version": 3, "metrics": NSNull()',1)
s=s.replace('  func metrics(_ metrics: URLSessionTaskMetrics) {','''  // 0 valid, 1 missing start, 2 missing end, 3 both missing, 4 invalid pair.
  // Only categorical reasons leave Foundation; no absolute dates or identities.
  static func intervalState(from start: Date?, to end: Date?) -> Int {
    guard let start else { return end == nil ? 3 : 1 }
    guard let end else { return 2 }
    return interval(from: start, to: end) == nil ? 4 : 0
  }
  func metrics(_ metrics: URLSessionTaskMetrics) {''',1)
needle='      return ["fetchSeconds": duration(t.fetchStartDate, t.responseEndDate),'
s=s.replace(needle,'''      let states = ["fetchSeconds": Self.intervalState(from: t.fetchStartDate, to: t.responseEndDate),
        "fetchToRequestSeconds": Self.intervalState(from: t.fetchStartDate, to: t.requestStartDate),
        "dnsSeconds": Self.intervalState(from: t.domainLookupStartDate, to: t.domainLookupEndDate),
        "connectSeconds": Self.intervalState(from: t.connectStartDate, to: t.connectEndDate),
        "tlsSeconds": Self.intervalState(from: t.secureConnectionStartDate, to: t.secureConnectionEndDate),
        "requestSeconds": Self.intervalState(from: t.requestStartDate, to: t.requestEndDate),
        "responseWaitSeconds": Self.intervalState(from: t.requestEndDate, to: t.responseStartDate),
        "responseSeconds": Self.intervalState(from: t.responseStartDate, to: t.responseEndDate)]
      return ["durationStates": states, "fetchSeconds": duration(t.fetchStartDate, t.responseEndDate),''',1)
s=s.replace('v["metrics"] = ["taskSeconds": duration', 'v["metrics"] = ["version": 2, "taskSeconds": duration',1);p.write_text(s)
p=Path('tool/playback_network/transaction_metrics.py');s=p.read_text()
s=s.replace("    require(isinstance(metrics, dict) and set(metrics) ==\n            {'taskSeconds', 'transactionCount', 'redirectCount', 'truncated', 'transactions'})", "    require(isinstance(metrics, dict))\n    v2 = 'version' in metrics\n    require(not v2 or (type(metrics['version']) is int and metrics['version']==2))\n    require(set(metrics) == {'taskSeconds', 'transactionCount', 'redirectCount', 'truncated', 'transactions'} | ({'version'} if v2 else set()))")
s=s.replace("require(isinstance(item, dict) and set(item) == DURATIONS | {'reused', 'protocolCode', 'fetchType'})", "require(isinstance(item, dict) and set(item) == DURATIONS | {'reused', 'protocolCode', 'fetchType'} | ({'durationStates'} if v2 else set()))")
needle="        require(integer(item['reused'], 1) and integer(item['protocolCode'], 3) and integer(item['fetchType'], 3))"
s=s.replace(needle,needle+'''
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
''');p.write_text(s)
p=Path('tool/playback_network/proxy_boundaries.py');s=p.read_text().replace("in (1, 2)","in (1, 2, 3)").replace("(row['version'] == 2)","(row['version'] >= 2)").replace("row['version'] == 2 and row['outcome'] == 0","row['version'] >= 2 and row['outcome'] == 0")
s=s.replace("        transaction_metrics = summarize_transactions(row.get('metrics'))", "        transaction_metrics = summarize_transactions(row.get('metrics'))\n        if row['version']==3 and row.get('metrics') is not None:\n            require(transaction_metrics.get('version')==2)")
p.write_text(s)
p=Path('tool/playback_network/abr_accesslog.py');p.write_text(p.read_text().replace("proxy_trace_version(rows) in (1, 2)","proxy_trace_version(rows) in (1, 2, 3)"))
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text().replace('"proxyRequestSamplingVersion": 2','"proxyRequestSamplingVersion": 3')
s=s.replace('    let start = Date(timeIntervalSince1970: 100)\n    XCTAssertNil(YlHlsProxyRequestTrace.interval', '''    let start = Date(timeIntervalSince1970: 100)
    XCTAssertEqual(YlHlsProxyRequestTrace.intervalState(from: nil, to: start), 1)
    XCTAssertEqual(YlHlsProxyRequestTrace.intervalState(from: start, to: nil), 2)
    XCTAssertEqual(YlHlsProxyRequestTrace.intervalState(from: nil, to: nil), 3)
    XCTAssertEqual(YlHlsProxyRequestTrace.intervalState(from: start, to: start.addingTimeInterval(-1)), 4)
    XCTAssertEqual(YlHlsProxyRequestTrace.intervalState(from: start, to: Date(timeIntervalSince1970: .infinity)), 4)
    XCTAssertEqual(YlHlsProxyRequestTrace.intervalState(from: start, to: start), 0)
    XCTAssertNil(YlHlsProxyRequestTrace.interval''',1);p.write_text(s)
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/YlDashResourceLoaderTests.swift').write_text('@testable import yl_player_media_core\n'+s)
p=Path('tool/playback_network/test_proxy_boundaries.py');s=p.read_text().replace("early=copy.deepcopy(row['metrics']['transactions'][0]);early['responseSeconds']=None;early['durationStates']['responseSeconds']=2", "early=copy.deepcopy(row['metrics']['transactions'][0])\n        for k,state in [('fetchSeconds',2),('responseWaitSeconds',2),('responseSeconds',3)]:early[k]=None;early['durationStates'][k]=state");p.write_text(s)
