from pathlib import Path
p=Path('packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/HLS/YlHlsMediaProxy.swift');s=p.read_text()
s=s.replace('if case .failed = state { self.close(connection, diagnosticCancelCause: 3) }','if case .failed(let error) = state {\n        self.close(connection, diagnosticCancelCause: 3, diagnosticCancelSource: 1, diagnosticError: error)\n      }')
a='self.close(connection, diagnosticCancelCause: 3)';assert s.count(a)==2
s=s.replace(a,'self.close(connection, diagnosticCancelCause: 3, diagnosticCancelSource: 2, diagnosticError: error)',1)
s=s.replace(a,'self.close(connection, diagnosticCancelCause: 3, diagnosticCancelSource: 3, diagnosticError: error)',1)
s=s.replace('private func close(_ connection: NWConnection, diagnosticCancelCause: Int = 4) {','private func close(_ connection: NWConnection, diagnosticCancelCause: Int = 4,\n    diagnosticCancelSource: Int = 0, diagnosticError: NWError? = nil) {')
s=s.replace('trace?.finish(outcome: 1, cancelCause: diagnosticCancelCause)','trace?.finish(outcome: 1, cancelCause: diagnosticCancelCause,\n      cancelSource: diagnosticCancelSource, error: diagnosticError)')
s=s.replace('if let resourceToken { values["version"] = 6;', 'if let resourceToken { values["version"] = 7;')
s=s.replace('// 2 downstream EOF, 3 downstream error, 4 other local close.\n  func finish(outcome: Int, cancelCause: Int = 4) {','''// 2 incomplete-request EOF, 3 downstream error, 4 other local close.
  // v7 sources: 0 not an error, 1 state.failed, 2 request receive,
  // 3 admitted-request monitor receive. This is the first recorded terminal
  // callback, not proof of the underlying peer's intent or physical ordering.
  func finish(outcome: Int, cancelCause: Int = 4, cancelSource: Int = 0, error: NWError? = nil) {''')
a='      values["cancelCause"] = outcome == 1 ? cancelCause : 0'
s=s.replace(a,a+'''
      if values["version"] as? Int == 7 {
        let recordsError = outcome == 1 && cancelCause == 3
        var domain = 0, code = 0
        if recordsError {
          switch error {
          case .posix(let value): domain = 1; code = Int(value.rawValue)
          case .dns(let value): domain = 2; code = Int(value)
          case .tls(let value): domain = 3; code = Int(value)
          default: domain = 4
          }
        }
        values["cancelSource"] = recordsError ? cancelSource : 0
        values["cancelErrorDomain"] = domain
        values["cancelErrorCode"] = code
      }''')
p.write_text(s)
p=Path('tool/playback_network/proxy_boundaries.py');s=p.read_text().replace('(1, 2, 3, 4, 5, 6)', '(1, 2, 3, 4, 5, 6, 7)')
s=s.replace("'cancelCause', 'resourceToken'}","'cancelCause', 'resourceToken', 'cancelSource', 'cancelErrorDomain', 'cancelErrorCode'}")
a="        require(('resourceToken' in row) == (row['version'] >= 6))"
s=s.replace(a,'''        error_fields = {'cancelSource', 'cancelErrorDomain', 'cancelErrorCode'}
        require((error_fields <= row.keys()) if row['version'] >= 7 else not error_fields.intersection(row))
        if row['version'] >= 7:
            source, domain, code = (row[k] for k in ('cancelSource', 'cancelErrorDomain', 'cancelErrorCode'))
            require(type(source) is int and source in range(4))
            require(type(domain) is int and domain in range(5))
            require(type(code) is int and -(2**31) <= code < 2**31)
            if row['cancelCause'] == 3:
                require(source in (1, 2, 3) and domain in (1, 2, 3, 4))
                if domain == 4: require(code == 0)
            else:
                require(source == domain == code == 0)
'''+a)
s=s.replace("'metrics', 'resourceToken')))","'metrics', 'resourceToken', 'cancelErrorCode')))")
s=s.replace("require(row['version'] == 6)","require(row['version'] >= 6)")
s=s.replace("cancelCause=row.get('cancelCause'), resourceToken=row.get('resourceToken')))","cancelCause=row.get('cancelCause'), resourceToken=row.get('resourceToken'),\n            cancelSource=row.get('cancelSource'), cancelErrorDomain=row.get('cancelErrorDomain'),\n            cancelErrorCode=row.get('cancelErrorCode')))")
p.write_text(s)
for name in ['bandwidth_diagnostics.py','abr_accesslog.py']:
 p=Path('tool/playback_network')/name;p.write_text(p.read_text().replace('(1, 2, 3, 4, 5, 6)', '(1, 2, 3, 4, 5, 6, 7)'))
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text().replace('"proxyRequestSamplingVersion": 6','"proxyRequestSamplingVersion": 7').replace('XCTAssertEqual(row["version"] as? Int, 6)','XCTAssertEqual(row["version"] as? Int, 7)')
p.write_text(s)
for platform in ('ios','macos'):Path(f'packages/yl_player/example/{platform}/RunnerTests/{p.name}').write_text('@testable import yl_player_media_core\n'+s)
