@testable import yl_player_apple
import XCTest

final class YlHlsHeaderPolicyTests: XCTestCase {
  func testSensitiveHeadersStayOnNormalizedSameOrigin() {
    let policy = YlHlsHeaderPolicy(
      originURL: URL(string: "https://Media.Test:443/master.m3u8")!,
      headers: [
        "Authorization": "Bearer secret",
        "cOoKiE": "session=secret",
        "Proxy-Authorization": "Basic secret",
        "X-Client": "tv",
      ]
    )

    let sameOrigin = policy.headers(for: URL(string: "https://MEDIA.test/seg.ts")!)
    XCTAssertEqual(sameOrigin["Authorization"], "Bearer secret")
    XCTAssertEqual(sameOrigin["cOoKiE"], "session=secret")
    XCTAssertEqual(sameOrigin["Proxy-Authorization"], "Basic secret")

    let crossOrigin = policy.headers(for: URL(string: "https://cdn.test/seg.ts")!)
    XCTAssertNil(crossOrigin["Authorization"])
    XCTAssertNil(crossOrigin["cOoKiE"])
    XCTAssertNil(crossOrigin["Proxy-Authorization"])
    XCTAssertEqual(crossOrigin["X-Client"], "tv")
  }

  func testSchemeAndNonDefaultPortArePartOfOrigin() {
    let policy = YlHlsHeaderPolicy(
      originURL: URL(string: "https://media.test:8443/master.m3u8")!,
      headers: ["Authorization": "Bearer secret"]
    )

    XCTAssertNotNil(policy.headers(
      for: URL(string: "https://media.test:8443/a.ts")!
    )["Authorization"])
    XCTAssertNil(policy.headers(
      for: URL(string: "https://media.test/a.ts")!
    )["Authorization"])
    XCTAssertNil(policy.headers(
      for: URL(string: "http://media.test:8443/a.ts")!
    )["Authorization"])
  }

  func testDefaultHTTPPortNormalizesToImplicitPort() {
    let policy = YlHlsHeaderPolicy(
      originURL: URL(string: "http://media.test:80/master.m3u8")!,
      headers: ["Cookie": "id=1"]
    )

    XCTAssertEqual(
      policy.headers(for: URL(string: "http://MEDIA.TEST/a.ts")!)["Cookie"],
      "id=1"
    )
  }
}
