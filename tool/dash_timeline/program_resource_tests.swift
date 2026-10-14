import Foundation
var results: [[String: Any]] = []
func check(_ name: String, _ body: () throws -> Bool) {
  do { results.append(["name": name, "passed": try body()]) }
  catch { results.append(["name": name, "passed": false, "error": String(describing: error)]) }
}
let origin = URL(string: "https://origin.example/media")!
func response(_ url: URL, _ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
  HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
}
final class Hop: YlDashResourceHop {
  let run: () -> Void
  var cancelled = false
  init(_ run: @escaping () -> Void) { self.run = run }
  func start() { run() }
  func cancel() { cancelled = true }
}
func resource(_ urls: [URL] = [origin], range: YlDashProgram.Resource.ByteRange? = nil) -> YlDashProgram.Resource {
  .init(candidates: urls.map { .init(url: $0, credentialsStripped: false) }, range: range)
}
func config(_ retries: Int = 0, redirects: Int = 3) -> YlNetworkConfiguration {
  .init(map: ["maxRetries": retries, "maxRedirects": redirects, "baseRetryDelayMs": 0, "maxRetryDelayMs": 0, "connectTimeoutMs": 50, "readTimeoutMs": 50])
}
func reader(_ configuration: YlNetworkConfiguration = config(), _ factory: @escaping YlDashProgramResources.Factory) -> YlDashProgramResources {
  .init(source: origin, headers: ["X-Public": "yes"], credentials: ["Authorization": "owned-test"], configuration: configuration, factory: factory)
}
func errorCode(_ expected: String, _ body: () throws -> Void) -> Bool {
  do { try body(); return false } catch let error as NativePlayerError { return error.code == expected } catch { return false }
}
check("exact response preserves credentials and bytes") {
  let r = reader { request, receive in
    Hop {
      if request.value(forHTTPHeaderField: "Authorization") != "owned-test" { receive(.complete(URLError(.cancelled))); return }
      receive(.headers(response(request.url!, 200, ["Content-Length": "3"]))); receive(.body(Data([1,2,3]))); receive(.complete(nil))
    }
  }
  return try r.read(resource(), maximumBytes: 4, cancellation: .init()).data == Data([1,2,3])
}
check("exact Range request and response") {
  let r = reader { request, receive in Hop {
    if request.value(forHTTPHeaderField: "Range") != "bytes=10-12" { receive(.complete(URLError(.cancelled))); return }
    receive(.headers(response(request.url!, 206, ["Content-Range": "bytes 10-12/100", "Content-Length": "3"]))); receive(.body(Data([4,5,6]))); receive(.complete(nil))
  } }
  let value = try r.read(resource(range: .init(start: 10, length: 3)), maximumBytes: 4, cancellation: .init())
  return value.data == Data([4,5,6]) && value.resourceLength == 100
}
check("Range cannot accept full file") {
  let r = reader { request, receive in Hop { receive(.headers(response(request.url!, 200))); receive(.body(Data([1]))); receive(.complete(nil)) } }
  return errorCode("network.range_invalid") { _ = try r.read(resource(range: .init(start: 10, length: 3)), maximumBytes: 4, cancellation: .init()) }
}
check("wrong Range is rejected") {
  let r = reader { request, receive in Hop { receive(.headers(response(request.url!, 206, ["Content-Range": "bytes 11-13/100"]))); receive(.complete(nil)) } }
  return errorCode("network.range_invalid") { _ = try r.read(resource(range: .init(start: 10, length: 3)), maximumBytes: 4, cancellation: .init()) }
}
check("oversized body rejected before retention") {
  let r = reader { request, receive in Hop { receive(.headers(response(request.url!, 200))); receive(.body(Data(repeating: 1, count: 10))); receive(.complete(nil)) } }
  return errorCode("resource.exhausted") { _ = try r.read(resource(), maximumBytes: 4, cancellation: .init()) }
}
check("truncated advertised payload rejected") {
  let r = reader { request, receive in Hop { receive(.headers(response(request.url!, 200, ["Content-Length": "4"]))); receive(.body(Data([1]))); receive(.complete(nil)) } }
  return errorCode("network.response_invalid") { _ = try r.read(resource(), maximumBytes: 4, cancellation: .init()) }
}
check("cross origin returning to origin stays stripped") {
  var sent: [String?] = [], calls = 0
  let r = reader { request, receive in
    calls += 1; sent.append(request.value(forHTTPHeaderField: "Authorization")); let call = calls
    return Hop {
      if call == 1 { receive(.headers(response(request.url!, 302, ["Location": "https://other.example/redirect"]))) }
      else if call == 2 { receive(.headers(response(request.url!, 302, ["Location": origin.absoluteString]))) }
      else { receive(.headers(response(request.url!, 200))); receive(.body(Data([1]))); receive(.complete(nil)) }
    }
  }
  let value = try r.read(resource(), maximumBytes: 4, cancellation: .init())
  return calls == 3 && sent[0] == "owned-test" && sent[1] == nil && sent[2] == nil && value.credentialsStripped
}
check("alternative spends shared retry budget") {
  var calls = 0
  let r = reader(config(1)) { request, receive in calls += 1; return Hop { receive(.headers(response(request.url!, 503))); receive(.complete(nil)) } }
  return errorCode("network.http_status") { _ = try r.read(resource([origin, URL(string: "https://other.example/file")!]), maximumBytes: 4, cancellation: .init()) } && calls == 2
}
check("successful alternative never restores credentials") {
  var calls = 0, sent: [String?] = []
  let r = reader(config(1)) { request, receive in calls += 1; sent.append(request.value(forHTTPHeaderField: "Authorization")); let call = calls; return Hop {
    if call == 1 { receive(.headers(response(request.url!, 503))) }
    else { receive(.headers(response(request.url!, 200))); receive(.body(Data([1]))); receive(.complete(nil)) }
  } }
  _ = try r.read(resource([origin, URL(string: "https://other.example/file")!]), maximumBytes: 4, cancellation: .init())
  return calls == 2 && sent[1] == nil
}
check("authentication failure is not retried") {
  var calls = 0
  let r = reader(config(2)) { request, receive in calls += 1; return Hop { receive(.headers(response(request.url!, 403))); receive(.complete(nil)) } }
  return errorCode("network.forbidden") { _ = try r.read(resource(), maximumBytes: 4, cancellation: .init()) } && calls == 1
}
check("redirect limit spans all hops") {
  var calls = 0
  let r = reader(config(0, redirects: 1)) { request, receive in calls += 1; return Hop { receive(.headers(response(request.url!, 302, ["Location": "/next"]))) } }
  return errorCode("network.redirect_limit") { _ = try r.read(resource(), maximumBytes: 4, cancellation: .init()) } && calls == 2
}
check("cancel before request performs no IO") {
  var calls = 0; let token = YlOpenCancellationToken(); token.cancel()
  let r = reader { _, _ in calls += 1; return Hop {} }
  return errorCode("network.cancelled") { _ = try r.read(resource(), maximumBytes: 4, cancellation: token) } && calls == 0
}
check("cancel active hop terminates reader") {
  let token = YlOpenCancellationToken(); var hop: Hop?
  let r = reader { _, _ in let value = Hop { token.cancel() }; hop = value; return value }
  return errorCode("network.cancelled") { _ = try r.read(resource(), maximumBytes: 4, cancellation: token) } && hop?.cancelled == true
}
check("connect timeout terminates stalled hop") {
  var hop: Hop?
  let r = reader { _, _ in let value = Hop {}; hop = value; return value }
  return errorCode("network.timeout") { _ = try r.read(resource(), maximumBytes: 4, cancellation: .init()) } && hop?.cancelled == true
}
check("read timeout terminates stalled body") {
  let r = reader { request, receive in Hop { receive(.headers(response(request.url!, 200))) } }
  return errorCode("network.timeout") { _ = try r.read(resource(), maximumBytes: 4, cancellation: .init()) }
}
check("invalid Range overflow rejected before request") {
  var calls = 0; let r = reader { _, _ in calls += 1; return Hop {} }
  return errorCode("network.range_invalid") { _ = try r.read(resource(range: .init(start: Int64.max, length: 2)), maximumBytes: 4, cancellation: .init()) } && calls == 0
}
check("terminal failure survives internal reopen") {
  var calls = 0
  let r = reader(config(1)) { request, receive in calls += 1; return Hop { receive(.headers(response(request.url!, 503))) } }
  let first = errorCode("network.http_status") { _ = try r.read(resource(), maximumBytes: 4, cancellation: .init()) }
  let second = errorCode("network.http_status") { _ = try r.read(resource(), maximumBytes: 4, cancellation: .init()) }
  return first && second && calls == 2
}
check("successful cross-origin history survives reopen") {
  var calls = 0, sent: [String?] = []
  let r = reader { request, receive in
    calls += 1; sent.append(request.value(forHTTPHeaderField: "Authorization")); let call = calls
    return Hop {
      if call == 1 { receive(.headers(response(request.url!, 302, ["Location": "https://other.example/file"]))) }
      else { receive(.headers(response(request.url!, 200))); receive(.body(Data([1]))); receive(.complete(nil)) }
    }
  }
  _ = try r.read(resource(), maximumBytes: 4, cancellation: .init())
  _ = try r.read(resource(), maximumBytes: 4, cancellation: .init())
  return calls == 3 && sent[2] == nil
}
check("unsolicited partial response rejected") {
  let r = reader { request, receive in Hop { receive(.headers(response(request.url!, 206, ["Content-Range": "bytes 0-0/2"]))); receive(.body(Data([1]))); receive(.complete(nil)) } }
  return errorCode("network.range_invalid") { _ = try r.read(resource(), maximumBytes: 4, cancellation: .init()) }
}
check("response reservation lives with returned bytes") {
  final class Lease { let released: () -> Void; init(_ released: @escaping () -> Void) { self.released = released }; deinit { released() } }
  var alive = 0, reserved = 0
  let r = YlDashProgramResources(source: origin, headers: [:], credentials: [:], configuration: config(), factory: { request, receive in Hop { receive(.headers(response(request.url!, 200))); receive(.body(Data([1]))); receive(.complete(nil)) } }, reserve: { bytes in
    reserved = bytes; alive += 1; return Lease { alive -= 1 }
  })
  var payload: YlDashProgramResources.Payload? = try r.read(resource(), maximumBytes: 4, cancellation: .init())
  let held = alive == 1 && reserved == 2 && payload?.data == Data([1])
  payload = nil
  return held && alive == 0
}
check("empty body callbacks do not extend read deadline") {
  final class EmptyHop: YlDashResourceHop {
    let receive: (YlDashResourceEvent) -> Void
    var timer: DispatchSourceTimer?
    init(_ receive: @escaping (YlDashResourceEvent) -> Void) { self.receive = receive }
    func start() {
      receive(.headers(response(origin, 200)))
      let timer = DispatchSource.makeTimerSource(); self.timer = timer
      timer.schedule(deadline: .now(), repeating: 0.005)
      timer.setEventHandler { [receive] in receive(.body(Data())) }; timer.resume()
    }
    func cancel() { timer?.cancel() }
  }
  let token = YlOpenCancellationToken()
  DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { token.cancel() }
  let r = reader { _, receive in EmptyHop(receive) }
  return errorCode("network.timeout") { _ = try r.read(resource(), maximumBytes: 4, cancellation: token) }
}
check("inherited source inspection cannot restore credentials") {
  var sent: [String?] = []
  let r = YlDashProgramResources(source: origin, headers: [:], credentials: ["Authorization": "secret"],
    credentialsAllowed: false, configuration: config(), factory: { request, receive in
      sent.append(request.value(forHTTPHeaderField: "Authorization"))
      return Hop { receive(.headers(response(request.url!, 200))); receive(.body(Data([1]))); receive(.complete(nil)) }
    })
  let payload = try r.read(resource(), maximumBytes: 4, cancellation: .init())
  return sent.count == 1 && sent[0] == nil && payload.credentialsStripped
}
check("root inspection and MPD share retry intent") {
  let intent = YlManagedRequestIntent(); _ = intent.nextRetry(maximum: 1)
  var calls = 0
  let r = YlDashProgramResources(source: origin, headers: [:], credentials: [:], rootIntent: intent,
    configuration: config(1), factory: { request, receive in
      calls += 1; return Hop { receive(.headers(response(request.url!, 503))); receive(.complete(nil)) }
    })
  return errorCode("network.http_status") { _ = try r.read(resource(), maximumBytes: 4, cancellation: .init()) } && calls == 1
}
print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), encoding: .utf8)!)
