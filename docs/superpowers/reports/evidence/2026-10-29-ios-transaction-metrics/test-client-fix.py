from pathlib import Path
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift');s=p.read_text();old='''    URLSession.shared.dataTask(with: try proxy.proxyURL(for: server.url("/private?token=secret"))) { body, _, error in
      XCTAssertNil(error); XCTAssertEqual(body, Data([1, 2, 3, 4])); bodyDone.fulfill()
    }.resume()
    wait(for: [bodyDone, boundary], timeout: 4)''';new='''    // Keep the downstream connection alive until proxy EOF. URLSession may
    // close as soon as Content-Length bytes arrive, before upstream completion.
    let url = try proxy.proxyURL(for: server.url("/private?token=secret"))
    let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(url.port!))!, using: .tcp)
    defer { client.cancel() }
    let ready = expectation(description: "downstream ready")
    client.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
    client.start(queue: DispatchQueue(label: "proxy.metrics.test.client"))
    wait(for: [ready], timeout: 2)
    var payload = Data()
    func receive() {
      client.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
        XCTAssertNil(error)
        if let data { payload.append(data) }
        if complete || error != nil {
          XCTAssertEqual(Data(payload.suffix(4)), Data([1, 2, 3, 4])); bodyDone.fulfill()
        } else { receive() }
      }
    }
    receive()
    client.send(content: Data("GET \\(url.path) HTTP/1.1\\r\\nHost: owned\\r\\n\\r\\n".utf8),
      completion: .contentProcessed { XCTAssertNil($0) })
    wait(for: [bodyDone, boundary], timeout: 4)'''
assert old in s;s=s.replace(old,new);p.write_text(s)
import sys
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter')
from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/{p.name}').write_bytes(native_test_source(p))
