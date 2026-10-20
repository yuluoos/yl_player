import Foundation
import CoreVideo
import FlutterMacOS

@main struct MediaDeliveryTests {
  static func spin(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(60)
    while !predicate() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(predicate(), "Timed out")
  }
  static func main() throws {
    setbuf(stdout, nil)
    try channelAdmission()
    try admission()
    var cleanups = 0
    var events = [[String: Any]]()
    var failureObserver: ((NativePlayerError) -> Void)?
    let gate = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    let manager = YlMediaDeliveryManager(configuration: PlayerConfiguration(map: [:]), prepare: { source, _, token in
      if source.uri.contains("wait") {
        token.onCancel { gate.signal() }
        entered.signal()
        _ = gate.wait(timeout: .now() + 5)
        try token.throwIfCancelled()
      }
      return YlAirPlayPreparedMedia(url: URL(string: "http://127.0.0.1:1234/token/index.m3u8")!, cleanup: { cleanups += 1 }, observeFailure: { failureObserver = $0 })
    }, currentAddress: { "127.0.0.1" })
    manager.onState = { events.append($0) }
    var first: Result<[String: Any], Error>?
    manager.prepare(id: "first", source: .init(uri: "rtmp://example.com/live/a", kind: .network, intent: .live)) { first = $0 }
    spin { first != nil }
    _ = try first!.get()
    var pending: Result<[String: Any], Error>?
    manager.prepare(id: "pending", source: .init(uri: "rtmp://example.com/live/wait", kind: .network, intent: .live)) { pending = $0 }
    precondition(entered.wait(timeout: .now() + 5) == .success)
    var rejectedReplacement: Result<[String: Any], Error>?
    manager.prepare(id: "rejected-replacement", source: .init(uri: "https://example.com/live.flv", kind: .network,
      formatHint: .flv, intent: .live, networkPolicy: .managed)) { rejectedReplacement = $0 }
    spin { rejectedReplacement != nil }
    if case .success = rejectedReplacement! { fatalError("Managed replacement was accepted") }
    precondition(pending == nil, "Rejected admission cancelled the existing preparation")
    manager.release(id: "pending")
    spin { pending != nil }
    if case .success = pending! { fatalError("Cancelled preparation succeeded") }
    precondition(cleanups == 0, "Cancelling replacement released accepted media")
    failureObserver?(NativePlayerError(category: "network", code: "network.failed", message: "private URL"))
    spin { events.contains { $0["status"] as? String == "failed" } }
    precondition(cleanups == 1, "Failed producer was not released")
    var second: Result<[String: Any], Error>?
    manager.prepare(id: "second", source: .init(uri: "rtmp://example.com/live/b", kind: .network, intent: .live)) { second = $0 }
    spin { second != nil }
    _ = try second!.get()
    manager.close(); manager.close()
    precondition(cleanups == 2, "Dispose must retire accepted producer once")
    print("PASS standalone media delivery cancellation, failure cleanup, retained old lease and dispose")
    var address = "127.0.0.1"
    var networkEvents = [[String: Any]]()
    let changing = YlMediaDeliveryManager(configuration: PlayerConfiguration(map: [:]), prepare: { _, _, _ in
      YlAirPlayPreparedMedia(url: URL(string: "http://127.0.0.1:1234/token/index.m3u8")!, cleanup: { cleanups += 1 })
    }, currentAddress: { address })
    changing.onState = { networkEvents.append($0) }
    var networkReady = false
    changing.prepare(id: "network", source: .init(uri: "rtmp://example.com/live/a", kind: .network)) { _ in networkReady = true }
    spin { networkReady }
    address = "192.168.2.3"
    spin { networkEvents.contains { $0["status"] as? String == "failed" } }
    precondition(cleanups == 3, "Interface change did not release the server")
    changing.close()
    print("PASS interface changes invalidate and retire delivery resource")
    if CommandLine.arguments.count > 1 { try live(CommandLine.arguments[1]) }
  }
  static func channelAdmission() throws {
    let transport = DeliveryTransport()
    let host = YlApplePlayerHost(playerId: 97, suffix: "admission",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 100),
      services: .init(platform: .current, textureOutput: DeliveryTexture(), makeDisplayDriver: { _ in DeliveryDisplay() }),
      callbacks: ApplePlayerFlutterApi(binaryMessenger: transport))
    let channels = YlMediaDeliveryChannels(messenger: transport)
    var starts = 0
    var cleanups = 0
    let gate = DispatchSemaphore(value: 0)
    let entered = DispatchSemaphore(value: 0)
    host.mediaDelivery = YlMediaDeliveryManager(configuration: PlayerConfiguration(map: [:]), prepare: { source, _, token in
      if source.uri.contains("wait") {
        token.onCancel { gate.signal() }
        entered.signal()
        _ = gate.wait(timeout: .now() + 5)
        try token.throwIfCancelled()
      }
      starts += 1
      return YlAirPlayPreparedMedia(url: URL(string: "http://127.0.0.1:1234/token/index.m3u8")!, cleanup: { cleanups += 1 })
    }, currentAddress: { "127.0.0.1" })
    channels.install(suffix: "admission", host: host)
    defer { host.close(); channels.install(suffix: "admission", host: nil) }
    func request(_ uri: String = "https://example.com/live.flv") -> AppleAssessRequest {
      .init(source: .init(kind: .network, locator: uri, intent: .live, format: .flv),
        options: .init(autoplay: false, bufferStrategy: .init(kind: .automatic), videoConstraints: .init()))
    }
    func call(_ method: String, _ id: String, _ request: AppleAssessRequest,
              _ completion: @escaping ([String: Any]) -> Void) {
      transport.call(["method": method, "id": id, "request": request], completion)
    }
    let valid = request()
    var admitted: [String: Any]?
    call("admit", "d1", valid) { admitted = $0 }
    spin { admitted != nil }
    precondition(admitted?["value"] as? Bool == true, "Native preflight did not admit valid input")
    precondition(starts == 0, "Preflight started a producer")
    var accepted: [String: Any]?
    call("prepare", "d1", valid) { accepted = $0 }
    spin { accepted != nil }
    precondition(accepted?["value"] is [String: Any])
    var pending: [String: Any]?
    call("prepare", "d2", request("https://example.com/wait.flv")) { pending = $0 }
    precondition(entered.wait(timeout: .now() + 5) == .success)
    var managed = valid
    managed.source.networkPolicy = .init(kind: .managed, connectTimeoutMs: 5000, readTimeoutMs: 5000,
      maxRetries: 1, baseRetryDelayMs: 100, maxRetryDelayMs: 1000, maxRedirects: 3)
    var position = valid
    position.options.startPositionMs = 100
    var size = valid
    size.options.videoConstraints.maxWidth = 640
    var buffer = valid
    buffer.options.bufferStrategy = .init(kind: .bounded, minDurationMs: 100, maxDurationMs: 500, maxManagedBytes: 1024)
    var conflict = valid
    conflict.source.format = .mp4
    for candidate in [managed, position, size, buffer, conflict] {
      var rejection: [String: Any]?
      call("admit", "d3", candidate) { rejection = $0 }
      spin { rejection != nil }
      precondition(rejection?["error"] is AppleFailureMessage, "Preflight ignored unsupported constraints")
      var prepared: [String: Any]?
      call("prepare", "d3", candidate) { prepared = $0 }
      spin { prepared != nil }
      let preflightCode = (rejection?["error"] as? AppleFailureMessage)?.code
      let prepareCode = (prepared?["error"] as? AppleFailureMessage)?.code
      precondition(preflightCode == prepareCode, "Preflight and prepare admission drifted")
      if candidate.source.networkPolicy?.kind == .managed { precondition(preflightCode == "policy.unsupported") }
      precondition(pending == nil && cleanups == 0 && starts == 1, "Rejected request changed existing resources")
    }
    var replacement: [String: Any]?
    call("prepare", "d4", valid) { replacement = $0 }
    spin { replacement != nil && pending != nil }
    precondition((pending?["error"] as? AppleFailureMessage)?.code == "load.cancelled")
    precondition(replacement?["value"] is [String: Any] && starts == 2 && cleanups == 1)
    host.close()
    precondition(cleanups == 2)
    print("PASS real native channel preflight and prepare share admission; rejection preserves pending/accepted resources and valid replacement cancels pending")
  }

  static func admission() throws {
    var starts = 0
    let manager = YlMediaDeliveryManager(configuration: PlayerConfiguration(map: [:]), prepare: { _, _, _ in
      starts += 1
      return YlAirPlayPreparedMedia(url: URL(string: "http://127.0.0.1:1234/token/index.m3u8")!, cleanup: {})
    }, currentAddress: { "127.0.0.1" })
    let rejected: [(String, YlAppleSourceDescriptor)] = [
      ("managed HTTP-FLV", .init(uri: "https://example.com/live.flv", kind: .network, formatHint: .flv, intent: .live, networkPolicy: .managed)),
      ("managed RTMP", .init(uri: "rtmp://example.com/live/a", kind: .network, intent: .live, networkPolicy: .managed)),
      ("explicit MP4 with FLV suffix", .init(uri: "https://example.com/live.flv", kind: .network, formatHint: .mp4, intent: .live)),
      ("explicit DASH with FLV suffix", .init(uri: "https://example.com/live.flv", kind: .network, formatHint: .dash, intent: .live)),
      ("automatic MP4", .init(uri: "https://example.com/live.mp4", kind: .network, intent: .live))
    ]
    var violations = [String]()
    for (name, source) in rejected {
      let before = starts
      var result: Result<[String: Any], Error>?
      manager.prepare(id: name, source: source) { result = $0 }
      spin { result != nil }
      if case .success = result! { violations.append("Accepted " + name) }
      if case .failure(let error) = result!, name.hasPrefix("managed"),
         (error as? NativePlayerError)?.code != "policy.unsupported" {
        violations.append("Managed policy rejection lost its stable code")
      }
      if starts != before { violations.append("Started producer for " + name) }
    }
    for violation in violations { print("FAIL admission: " + violation) }
    precondition(violations.isEmpty, "Unsupported delivery constraints must reject before production")
    let accepted: [YlAppleSourceDescriptor] = [
      .init(uri: "https://example.com/live.flv", kind: .network, intent: .live),
      .init(uri: "https://example.com/live", kind: .network, formatHint: .flv, intent: .live),
      .init(uri: "rtmp://example.com/live/a", kind: .network, intent: .live),
      .init(uri: "rtmps://example.com/live/a", kind: .network, formatHint: .flv, intent: .live)
    ]
    for (index, source) in accepted.enumerated() {
      var result: Result<[String: Any], Error>?
      manager.prepare(id: "accepted-\(index)", source: source) { result = $0 }
      spin { result != nil }
      _ = try result!.get()
    }
    precondition(starts == accepted.count)
    manager.close()
    print("PASS managed policy and conflicting explicit formats reject before producer; default live inputs retain admission")
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
    spin { result != nil }
    return try result!.get()
  }
  static func live(_ locator: String) throws {
    let manager = YlMediaDeliveryManager(configuration: PlayerConfiguration(map: [:]))
    var prepared: Result<[String: Any], Error>?
    manager.prepare(id: "live", source: .init(uri: locator, kind: .network, formatHint: .flv, intent: .live)) { prepared = $0 }
    spin { prepared != nil }
    let value = try prepared!.get()
    let url = URL(string: value["uri"] as! String)!
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
    let (_, headStatus) = try fetch(segmentURL, method: "HEAD")
    precondition(headStatus == 200)
    manager.close()
    do { _ = try fetch(url); fatalError("Closed delivery server remained reachable") } catch {}
    print("PASS standalone live receiver fetched playlist/init/segment/range/HEAD and disposal closed origin")
  }
}

private final class DeliveryTexture: YlTextureOutput {
  let textureId: Int64 = 97
  func publish(_ pixelBuffer: CVPixelBuffer?) {}
  func resize(width: Int, height: Int) {}
  func clear() {}
  func dispose() {}
}
private final class DeliveryDisplay: YlDisplayDriving {
  var isPaused = true
  func invalidate() {}
}
private final class DeliveryTransport: NSObject, FlutterBinaryMessenger {
  private var handlers = [String: FlutterBinaryMessageHandler]()
  func call(_ arguments: [String: Any], _ completion: @escaping ([String: Any]) -> Void) {
    let codec = YlPlayerApplePigeonCodec.shared
    guard let handler = handlers["dev.ylplayer.delivery.admission"] else { fatalError("Missing delivery channel") }
    handler(codec.encode(arguments)) { data in
      guard let value = codec.decode(data) as? [String: Any] else { fatalError("Malformed reply") }
      completion(value)
    }
  }
  func send(onChannel channel: String, message: Data?) {}
  func send(onChannel channel: String, message: Data?, binaryReply: FlutterBinaryReply?) {
    binaryReply?(YlPlayerApplePigeonCodec.shared.encode([NSNull()]))
  }
  func setMessageHandlerOnChannel(_ channel: String,
      binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    handlers[channel] = handler
    return 1
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {}
}
