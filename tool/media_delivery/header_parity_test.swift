import Foundation
import yl_player_media_core
@testable import yl_player_media_delivery
@testable import yl_player_apple

@main struct HeaderParityTests {
  struct Case {
    let name: String
    let headers: [String: String]
    let credentials: [String: String]
    let accepted: Bool
  }
  static func main() throws {
    var cases = [
      Case(name: "empty", headers: [:], credentials: [:], accepted: true),
      Case(name: "HTAB ordinary", headers: ["Accept": "video/x-flv\t; q=1"], credentials: [:], accepted: true),
      Case(name: "HTAB credential", headers: [:], credentials: ["Authorization": "Bearer\tsecret"], accepted: true),
      Case(name: "duplicate ordinary", headers: ["Accept": "a", "accept": "b"], credentials: [:], accepted: false),
      Case(name: "duplicate credential", headers: [:], credentials: ["X-Key": "a", "x-key": "b"], accepted: false),
      Case(name: "cross-map duplicate", headers: ["Accept": "a"], credentials: ["ACCEPT": "b"], accepted: false),
      Case(name: "invalid name", headers: ["X Bad": "value"], credentials: [:], accepted: false),
    ]
    for name in ["Host", "Content-Length", "Connection", "Transfer-Encoding", "Range", "If-Range"] {
      cases.append(Case(name: "reserved ordinary \(name)", headers: [name: "value"], credentials: [:], accepted: false))
      cases.append(Case(name: "reserved credential \(name)", headers: [:], credentials: [name: "value"], accepted: false))
    }
    for name in ["Authorization", "Cookie", "XToken", "XApiKey", "XSecret", "XCredential"] {
      cases.append(Case(name: "sensitive ordinary \(name)", headers: [name: "secret"], credentials: [:], accepted: false))
      cases.append(Case(name: "explicit credential \(name)", headers: [:], credentials: [name: "secret"], accepted: true))
    }
    for control in Array(0...31).filter({ $0 != 9 }) + [127] {
      let value = "a\(UnicodeScalar(control)!)b"
      cases.append(Case(name: "ordinary control \(control)", headers: ["Accept": value], credentials: [:], accepted: false))
      cases.append(Case(name: "credential control \(control)", headers: [:], credentials: ["X-Api-Key": value], accepted: false))
    }
    for item in cases {
      let old = Result {
        try YlAppleNativeInput.load(
          source: .init(kind: .network, locator: "https://example.com/live.flv", intent: .live, format: .flv,
            request: .init(headers: item.headers, credentials: item.credentials)),
          options: .init(autoplay: false, bufferStrategy: .init(kind: .automatic), videoConstraints: .init()),
          defaults: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 100),
          loadRequestId: nil)
      }
      let new = Result {
        try YlDeliveryWire.input(["id": "d1", "source": [
          "kind": "network", "uri": "https://example.com/live.flv", "intent": "live", "format": "flv",
          "headers": item.headers, "credentials": item.credentials, "networkPolicy": ["kind": "platformDefault"]
        ], "options": ["autoplay": false, "bufferStrategy": ["kind": "automatic"]]])
      }
      switch (old, new, item.accepted) {
      case (.success(let legacy), .success(let independent), true):
        precondition(legacy.source.headers == item.headers && legacy.source.credentials == item.credentials)
        guard case .network(let recipe, _) = independent.recipe else { fatalError("Missing network input") }
        precondition(recipe.headers == item.headers && recipe.credentials == item.credentials)
      case (.failure(let oldError as NativePlayerError), .failure(let newError as NativePlayerError), false):
        precondition(oldError.code == "source.invalid_argument" && newError.code == "source.invalid")
        precondition(!oldError.description.contains("secret") && !newError.description.contains("secret"))
      default: fatalError("Header admission differs or violates expected result: \(item.name)")
      }
    }
    let origin = URL(string: "https://example.com/live.flv")!
    let context = YlManagedRequestContext(sourceOrigin: YlRequestOrigin(url: origin)!,
      ordinaryHeaders: ["Accept": "video/x-flv\t; q=1"], credentials: ["X-Api-Key": "secret\tvalue"],
      credentialsAllowed: true, redirectsFollowed: 0)
    precondition(context.child(at: origin).headers["X-Api-Key"] == "secret\tvalue")
    let crossOrigin = context.child(at: URL(string: "https://cdn.example/live.flv")!, redirect: true)
    precondition(crossOrigin.headers["X-Api-Key"] == nil)
    precondition(crossOrigin.headers["Accept"] == context.ordinaryHeaders["Accept"])
    precondition(crossOrigin.child(at: origin).headers["X-Api-Key"] == nil)
    print("PASS \(cases.count) header cases through actual legacy and independent boundaries; credential stripping is monotonic")
  }
}
