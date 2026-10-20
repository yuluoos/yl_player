import Foundation
import FlutterMacOS
import yl_player_media_core
@testable import yl_player_media_delivery

@main struct StandaloneDeliveryTests {
  static func spin(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(60)
    while !predicate() && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    precondition(predicate(), "Timed out")
  }
  static func request(_ uri: String = "rtmps://example.com/live/a") -> [String: Any] {
    ["id": "d1", "source": ["kind": "network", "uri": uri, "intent": "live", "format": "flv",
      "headers": [String: String](), "credentials": [String: String](), "networkPolicy": ["kind": "platformDefault"]],
     "options": ["autoplay": false, "bufferStrategy": ["kind": "automatic"]]]
  }
  static func main() throws {
    setbuf(stdout, nil)
    try admission()
    try headerAdmission()
    try lifecycle()
    try channels()
    if CommandLine.arguments.count > 1 { try live(CommandLine.arguments[1]) }
  }
  static func admission() throws {
    let valid = request()
    _ = try YlDeliveryWire.input(valid)
    for field in ["networkPolicy", "drm", "intent", "format", "headers"] {
      var candidate = valid
      var source = candidate["source"] as! [String: Any]
      switch field {
      case "networkPolicy": source[field] = ["kind": "managed"]
      case "drm": source[field] = ["kind": "fairPlay"]
      case "intent": source[field] = "onDemand"
      case "format": source[field] = "mp4"
      default: source[field] = ["Authorization": "secret"]
      }
      candidate["source"] = source
      do { _ = try YlDeliveryWire.input(candidate); fatalError("Invalid \(field) admitted") }
      catch let error as NativePlayerError { precondition(!error.description.contains("secret")) }
    }
    for field in ["startPositionMs", "maxWidth", "maxHeight", "maxBitrate", "bufferStrategy"] {
      var candidate = valid
      var options = candidate["options"] as! [String: Any]
      options[field] = field == "bufferStrategy" ? ["kind": "bounded"] : 100
      candidate["options"] = options
      do { _ = try YlDeliveryWire.input(candidate); fatalError("Unsupported \(field) admitted") }
      catch let error as NativePlayerError { precondition(error.code == "policy.unsupported") }
    }
    let scopeA = NSObject(), scopeB = NSObject()
    YlMediaDeliveryRegistry.install(YlMediaDeliveryEngine(), for: ObjectIdentifier(scopeA))
    _ = try YlMediaDeliveryRegistry.service(for: ObjectIdentifier(scopeA))
    do { _ = try YlMediaDeliveryRegistry.service(for: ObjectIdentifier(scopeB)); fatalError("Engine leaked") }
    catch let error as NativePlayerError { precondition(error.code == "airplay.delivery_unavailable") }
    YlMediaDeliveryRegistry.remove(for: ObjectIdentifier(scopeA))
    print("PASS standalone wire admission and optional service engine isolation")
  }
  static func headerAdmission() throws {
    let rejected: [([String: String], [String: String])] = [
      (["X-Api-Key": "secret"], [:]), (["Authorization": "secret"], [:]),
      (["Host": "other.example"], [:]), ([:], ["Range": "bytes=0-1"]),
      (["Accept": "a", "accept": "b"], [:]),
      (["Accept": "a"], ["ACCEPT": "b"]),
      ([:], ["X-Token": "a", "x-token": "b"]),
      (["Accept": "video/x-flv\r\nX-Injected: true"], [:]),
      (["Accept": "bad\u{0}value"], [:]),
      ([:], ["Authorization": "bad\u{7f}value"]),
    ]
    for (headers, credentials) in rejected {
      var candidate = request("https://example.com/live.flv")
      var source = candidate["source"] as! [String: Any]
      source["headers"] = headers; source["credentials"] = credentials
      candidate["source"] = source
      do { _ = try YlDeliveryWire.input(candidate); fatalError("Unsafe header admitted") }
      catch let error as NativePlayerError { precondition(error.code == "source.invalid") }
    }
    var candidate = request("https://example.com/live.flv")
    var source = candidate["source"] as! [String: Any]
    source["headers"] = ["Accept": "video/x-flv\t; q=1"]
    source["credentials"] = ["X-Api-Key": "secret\tvalue"]
    candidate["source"] = source
    let input = try YlDeliveryWire.input(candidate)
    guard case .network(let recipe, _) = input.recipe else { fatalError("Missing network recipe") }
    precondition(recipe.credentials["X-Api-Key"] == "secret\tvalue")
    precondition(recipe.headers["Accept"] == "video/x-flv\t; q=1")
    print("PASS native headers preserve HTAB and reject controls, secrets, reserved names and duplicates")
  }
  static func lifecycle() throws {
    var cleanups = 0
    var events = [String]()
    var failureObserver: ((NativePlayerError) -> Void)?
    let gate = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
    let manager = YlMediaDeliveryManager(prepare: { input, token in
      if case .rtmp(let request) = input.recipe, request.address.playpath == "wait" {
        token.onCancel { gate.signal() }
        entered.signal(); _ = gate.wait(timeout: .now() + 5); try token.throwIfCancelled()
      }
      return YlDeliveredMedia(url: URL(string: "http://127.0.0.1:1234/token/index.m3u8")!,
        cleanup: { cleanups += 1 }, observeFailure: { failureObserver = $0 })
    }, currentAddress: { "127.0.0.1" })
    manager.onState = { _, status, _ in events.append(status) }
    var first: Result<URL, Error>?
    manager.prepare(id: "d1", input: try YlDeliveryWire.input(request())) { first = $0 }
    spin { first != nil }; _ = try first!.get()
    var pending: Result<URL, Error>?
    manager.prepare(id: "d2", input: try YlDeliveryWire.input(request("rtmp://example.com/live/wait"))) { pending = $0 }
    precondition(entered.wait(timeout: .now() + 5) == .success)
    var rejected: Result<URL, Error>?
    manager.prepare(id: "d3", input: YlMediaDeliveryInput(recipe: .local(path: "/missing", container: .flv), isLive: false)) { rejected = $0 }
    spin { rejected != nil }
    if case .success = rejected! { fatalError("Rejected candidate accepted") }
    precondition(pending == nil && cleanups == 0)
    manager.release(id: "d2"); spin { pending != nil }
    if case .success = pending! { fatalError("Cancellation ignored") }
    precondition(cleanups == 0)
    failureObserver?(NativePlayerError(category: "network", code: "network.failed", message: "secret"))
    spin { events.contains("failed") }; precondition(cleanups == 1)
    var second: Result<URL, Error>?
    manager.prepare(id: "d4", input: try YlDeliveryWire.input(request())) { second = $0 }
    spin { second != nil }; _ = try second!.get()
    manager.close(); manager.close(); precondition(cleanups == 2)
    print("PASS standalone rejection preserves old preparation/lease; cancel, failure and dispose release resources")
  }
  static func channels() throws {
    let messenger = DeliveryTestMessenger()
    var plugin: YlPlayerMediaDeliveryPlugin? = YlPlayerMediaDeliveryPlugin(messenger: messenger)
    let first = messenger.call("dev.ylplayer.media_delivery", "create") as! String
    let second = messenger.call("dev.ylplayer.media_delivery", "create") as! String
    precondition(first != second)
    precondition(messenger.call("dev.ylplayer.media_delivery.\(first)", "admit", request()) as? Bool == true)
    _ = messenger.call("dev.ylplayer.media_delivery.\(first)", "dispose")
    precondition(messenger.handlers["dev.ylplayer.media_delivery.\(first)"] == nil)
    precondition(messenger.call("dev.ylplayer.media_delivery.\(second)", "admit", request()) as? Bool == true)
    _ = messenger.call("dev.ylplayer.media_delivery.\(second)", "dispose")
    precondition(messenger.handlers.count == 1)
    precondition(plugin != nil); plugin = nil
    precondition(messenger.handlers.isEmpty)
    do { _ = try YlMediaDeliveryRegistry.service(for: ObjectIdentifier(messenger)); fatalError("Service retained") }
    catch let error as NativePlayerError { precondition(error.code == "airplay.delivery_unavailable") }
    print("PASS real Flutter owner channels create without player, isolate disposal and unregister")
  }
  static func fetch(_ url: URL, method: String = "GET", range: String? = nil) throws -> (Data, Int) {
    var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
    request.httpMethod = method
    if let range { request.setValue(range, forHTTPHeaderField: "Range") }
    var result: Result<(Data, Int), Error>?
    URLSession.shared.dataTask(with: request) { data, response, error in
      DispatchQueue.main.async {
        if let error { result = .failure(error) }
        else { result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0)) }
      }
    }.resume()
    spin { result != nil }; return try result!.get()
  }
  static func live(_ locator: String) throws {
    let manager = YlMediaDeliveryEngine().makeSession()
    var prepared: Result<URL, Error>?
    manager.prepare(id: "d1", input: try YlDeliveryWire.input(request(locator))) { prepared = $0 }
    spin { prepared != nil }
    let url = try prepared!.get()
    let (data, status) = try fetch(url)
    let playlist = String(data: data, encoding: .utf8)!
    precondition(status == 200 && playlist.contains("#EXTM3U") && !playlist.contains("#EXT-X-ENDLIST"))
    let initName = playlist.components(separatedBy: "URI=\"")[1].components(separatedBy: "\"")[0]
    let segment = playlist.split(separator: "\n").first { !$0.hasPrefix("#") }!
    let (initData, initStatus) = try fetch(url.deletingLastPathComponent().appendingPathComponent(initName))
    precondition(initStatus == 200 && !initData.isEmpty)
    let segmentURL = url.deletingLastPathComponent().appendingPathComponent(String(segment))
    let (rangeData, rangeStatus) = try fetch(segmentURL, range: "bytes=0-31")
    precondition(rangeStatus == 206 && rangeData.count == 32)
    let (_, headStatus) = try fetch(segmentURL, method: "HEAD"); precondition(headStatus == 200)
    manager.close()
    do { _ = try fetch(url); fatalError("Closed origin remains reachable") } catch {}
    print("PASS no-player production HTTP-FLV -> HLS playlist/init/segment/Range/HEAD; disposal closes origin")
  }
}

private final class DeliveryTestMessenger: NSObject, FlutterBinaryMessenger {
  var handlers = [String: FlutterBinaryMessageHandler]()
  private var connections = [Int64: String]()
  private var serial: Int64 = 0
  func call(_ channel: String, _ method: String, _ arguments: Any? = nil) -> Any? {
    let codec = FlutterStandardMethodCodec.sharedInstance()
    guard let handler = handlers[channel] else { fatalError("Missing channel") }
    var done = false
    var result: Any?
    handler(codec.encode(FlutterMethodCall(methodName: method, arguments: arguments))) { data in
      if let data { result = codec.decodeEnvelope(data) }
      done = true
    }
    StandaloneDeliveryTests.spin { done }; return result
  }
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply: FlutterBinaryReply?) { binaryReply?(nil) }
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    handlers[channel] = handler
    serial += 1; connections[serial] = channel; return serial
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {
    if let channel = connections.removeValue(forKey: connection) { handlers.removeValue(forKey: channel) }
  }
}
