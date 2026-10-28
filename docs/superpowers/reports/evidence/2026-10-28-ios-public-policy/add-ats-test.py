from pathlib import Path
import sys
p=Path('tool/consumer_fixtures/apple_flutter/RunnerTests/YlNetworkRequestPolicyTests.swift');s=p.read_text();i=s.index('  func testManagedTransportRejectsRequiredProxyAndATSRestrictions')
s=s[:i]+'''  func testManagedLocalNetworkingAdmitsLiteralAddressesButRetainsExplicitRestrictions() throws {
    for host in ["192.168.1.20", "10.0.0.2", "172.16.0.2", "203.0.113.7", "[2001:db8::1]", "[::ffff:192.0.2.1]"] {
      let url = try XCTUnwrap(URL(string: "http://\\(host)/bytes"))
      XCTAssertNoThrow(try YlManagedTransportRestrictions.validate(url: url,
        ats: ["NSAllowsLocalNetworking": true], proxySettings: [:]), host)
      XCTAssertThrowsError(try YlManagedTransportRestrictions.validate(url: url,
        ats: ["NSAllowsLocalNetworking": false], proxySettings: [:]), host)
      XCTAssertThrowsError(try YlManagedTransportRestrictions.validate(url: url,
        ats: ["NSAllowsLocalNetworking": true, "NSPinnedDomains": ["media.test": [:]]], proxySettings: [:]), host)
    }
    for host in ["192.168.1.20.example.test", "192.168.1.999", "media.test"] {
      XCTAssertThrowsError(try YlManagedTransportRestrictions.validate(url: XCTUnwrap(URL(string: "http://\\(host)/bytes")),
        ats: ["NSAllowsLocalNetworking": true], proxySettings: [:]), host)
    }
    let literal = try XCTUnwrap(URL(string: "http://192.168.1.20/bytes"))
    XCTAssertThrowsError(try YlManagedTransportRestrictions.validate(url: literal,
      ats: ["NSAllowsLocalNetworking": true, "NSExceptionDomains": ["192.168.1.20": [:]]], proxySettings: [:]))
    XCTAssertThrowsError(try YlManagedTransportRestrictions.validate(url: literal,
      ats: ["NSAllowsLocalNetworking": true],
      proxySettings: ["HTTPEnable": 1, "HTTPProxy": "proxy.test", "HTTPPort": 8080]))
  }

'''+s[i:];p.write_text(s)
sys.path.insert(0,'tool/consumer_fixtures/apple_flutter');from media_delivery_fixture_adapter import native_test_source
for platform in ['ios','macos']:Path(f'packages/yl_player/example/{platform}/RunnerTests/{p.name}').write_bytes(native_test_source(p))
p=Path('tool/consumer_fixtures/apple_flutter/main_example_tests.py');p.write_text(p.read_text().replace("{'ios': 836, 'macos': 880}","{'ios': 837, 'macos': 881}"))
p=Path('docs/superpowers/plans/2026-10-28-ios-public-policy.md');p.write_text(p.read_text()+'''\n新增已确认根因：public host加载在首请求前返回policy.unsupported，prepareDash的managed HTTP预检不识别IPv4字面量的NSAllowsLocalNetworking授权。Apple文档确认该配置覆盖IPv4/IPv6。先保留真机失败和原生产判断的单测红灯，再按文档修正字面地址识别；显式域名/代理/固定证书限制仍优先，既有ATS配置不改。因涉及共享media core，最终扩大到NetworkRequestPolicy原生矩阵和独立media-core消费者构建/契约检查。\n''')
