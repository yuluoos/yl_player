import yl_player_media_core
import Foundation

protocol YlDashResourceHop: AnyObject { func start(); func cancel() }
enum YlDashResourceEvent { case headers(HTTPURLResponse), body(Data), complete(Error?) }

/// One resource intent spans BaseURL alternatives and redirects. Its returned
/// payload retains the caller's reservation until the decoder/consumer releases it.
final class YlDashProgramResources {
  typealias Factory = (URLRequest, @escaping (YlDashResourceEvent) -> Void) throws -> any YlDashResourceHop
  final class Payload {
    let data: Data
    let finalURL: URL
    let credentialsStripped: Bool
    let resourceLength: Int64?
    /// Byte origin within the returned resource, retained for absolute MP4 offsets.
    let sourceOffset: Int64
    private let reservation: AnyObject?
    init(data: Data, finalURL: URL, credentialsStripped: Bool, resourceLength: Int64?, reservation: AnyObject?, sourceOffset: Int64 = 0) {
      self.data = data; self.finalURL = finalURL; self.credentialsStripped = credentialsStripped
      self.resourceLength = resourceLength; self.reservation = reservation; self.sourceOffset = sourceOffset
    }
  }
  private let context: YlManagedRequestContext?
  private let configuration: YlNetworkConfiguration
  private let factory: Factory
  private let reserve: (Int) throws -> AnyObject?
  private let historyLock = NSLock()
  private var history: [String: YlManagedRequestIntent] = [:]
  private var stripped: Set<String> = []

  init(source: URL, headers: [String: String], credentials: [String: String],
       credentialsAllowed: Bool = true, rootIntent: YlManagedRequestIntent? = nil,
       configuration: YlNetworkConfiguration, factory: @escaping Factory,
       reserve: @escaping (Int) throws -> AnyObject? = { _ in nil }) {
    context = YlRequestOrigin(url: source).map {
      YlManagedRequestContext(sourceOrigin: $0, ordinaryHeaders: headers,
        credentials: credentials, credentialsAllowed: credentialsAllowed, redirectsFollowed: 0)
    }
    self.configuration = configuration; self.factory = factory; self.reserve = reserve
    if let rootIntent {
      let absolute = source.absoluteString
      history["\(absolute.utf8.count):\(absolute)|full"] = rootIntent
    }
  }

  /// Synchronous worker-queue API. Callers must never block the render or main
  /// queue. Cancellation is checked every 20 ms without retaining per-hop token
  /// observers for the lifetime of a long programme.
  func read(_ resource: YlDashProgram.Resource, maximumBytes: Int,
            cancellation: YlOpenCancellationToken) throws -> Payload {
    try cancellation.throwIfCancelled()
    guard var context, !resource.candidates.isEmpty,
          resource.candidates.count <= 16 else { throw Self.error("network.request_invalid") }
    guard maximumBytes > 0, maximumBytes <= 64 * 1024 * 1024 else { throw Self.error("resource.exhausted") }
    var rangeHeader: String?
    if let range = resource.range {
      let (end, overflow) = range.start.addingReportingOverflow(range.length - (range.length > 0 ? 1 : 0))
      guard range.start >= 0, range.length > 0, !overflow else { throw Self.error("network.range_invalid") }
      guard range.length <= maximumBytes else { throw Self.error("resource.exhausted") }
      rangeHeader = "bytes=\(range.start)-\(end)"
    }
    // Length framing prevents URL delimiters from colliding with another intent.
    let lineage = resource.candidates.map { "\($0.url.absoluteString.utf8.count):\($0.url.absoluteString)" }.joined()
    let key = lineage + "|" + (rangeHeader ?? "full")
    historyLock.lock()
    if history[key] == nil, history.count >= 100_000 {
      historyLock.unlock(); throw Self.error("resource.exhausted")
    }
    let intent = history[key] ?? YlManagedRequestIntent()
    history[key] = intent
    let previouslyStripped = stripped.contains(lineage)
    historyLock.unlock()
    if let failure = intent.terminalFailure { throw failure }
    // Reserve both retained bytes and the bounded growth/copy transient. A hop
    // separately owns its HTTP parser/delivery reservation.
    let workspace = try reserve(maximumBytes * 2)
    defer { withExtendedLifetime(workspace) {} }
    var candidate = 0
    var url = resource.candidates[0].url
    context = context.child(at: url, previouslyStripped: previouslyStripped || resource.candidates[0].credentialsStripped)
    let policy = YlManagedRequestPolicy()
    do {
      while true {
        try cancellation.throwIfCancelled()
        guard YlRequestOrigin(url: url) != nil, url.user == nil, url.password == nil else {
          throw Self.error("network.request_invalid")
        }
        if !context.credentialsAllowed {
          historyLock.lock(); stripped.insert(lineage); historyLock.unlock()
        }
        var request = URLRequest(url: url)
        for (name, value) in context.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        let waiter = Waiter(maximum: maximumBytes, range: resource.range, configuration: configuration)
        var response: HTTPURLResponse?
        var failure: Error?
        do {
          let hop = try factory(request, waiter.receive)
          defer { waiter.seal(); hop.cancel() }
          hop.start()
          try waiter.wait(cancellation: cancellation)
          response = waiter.response
        } catch { failure = error }
        try cancellation.throwIfCancelled()
        if let response {
          let status = response.statusCode
          if [301, 302, 303, 307, 308].contains(status) {
            guard let location = response.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: location, relativeTo: url)?.absoluteURL,
                  YlRequestOrigin(url: next) != nil, next.user == nil, next.password == nil else {
              throw Self.error("network.redirect_invalid")
            }
            guard intent.followRedirect(maximum: configuration.maxRedirects) else {
              throw Self.error("network.redirect_limit")
            }
            url = next; context = context.child(at: next, redirect: true)
            continue
          }
          if status == 200 || status == 206 {
            intent.completed()
            // Compact the response into a separately metered immutable payload.
            // Keeping the admission maximum here falsely exhausts the ledger
            // after a few tiny fragments; the temporary growth lease ends below.
            let reservation = try reserve(waiter.data.count * 2)
            let bytes = waiter.data.withUnsafeBytes { Data($0) }
            return Payload(data: bytes, finalURL: url,
              credentialsStripped: !context.credentialsAllowed,
              resourceLength: waiter.resourceLength, reservation: reservation, sourceOffset: resource.range?.start ?? 0)
          }
          failure = Self.error(status == 401 ? "network.unauthorized" : status == 403 ? "network.forbidden" : "network.http_status")
        }
        let retryable = response.map { YlManagedRequestPolicy.isRetryableStatus($0.statusCode) }
          ?? failure.map { YlManagedRequestPolicy.isTransient($0) || ($0 as? NativePlayerError)?.code == "network.timeout" } ?? false
        guard retryable, let attempt = intent.nextRetry(maximum: configuration.maxRetries),
              let delay = policy.retryDelay(attempt: attempt, configuration: configuration,
                retryAfter: response?.value(forHTTPHeaderField: "Retry-After")) else {
          throw failure ?? Self.error("network.response_invalid")
        }
        let until = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, delay)) * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < until {
          try cancellation.throwIfCancelled(); Thread.sleep(forTimeInterval: 0.02)
        }
        candidate = (candidate + 1) % resource.candidates.count
        url = resource.candidates[candidate].url
        context = context.child(at: url, previouslyStripped: resource.candidates[candidate].credentialsStripped)
      }
    } catch {
      let value = (error as? NativePlayerError) ?? Self.error("network.request_failed")
      // Cancellation retires the current reader, not the resource's shared
      // budget; a subsequent seek may resume it without resetting that budget.
      if value.code != "network.cancelled" { intent.fail(value) }
      throw value
    }
  }

  private static func error(_ code: String) -> NativePlayerError {
    NativePlayerError(category: code.hasPrefix("resource.") ? "resource" : "network",
      code: code, message: "DASH resource could not be read within its managed policy.")
  }

  private final class Waiter {
    let condition = NSCondition()
    let maximum: Int
    let range: YlDashProgram.Resource.ByteRange?
    let configuration: YlNetworkConfiguration
    var response: HTTPURLResponse?
    var data = Data()
    var resourceLength: Int64?
    private var expectedLength: Int64?
    private var failure: Error?
    private var finished = false
    private var lastActivity = DispatchTime.now().uptimeNanoseconds

    init(maximum: Int, range: YlDashProgram.Resource.ByteRange?, configuration: YlNetworkConfiguration) {
      self.maximum = maximum; self.range = range; self.configuration = configuration
    }
    func seal() { condition.lock(); finished = true; condition.unlock() }
    func receive(_ event: YlDashResourceEvent) {
      condition.lock(); defer { condition.broadcast(); condition.unlock() }
      guard !finished else { return }
      if case .body(let bytes) = event, bytes.isEmpty { return }
      lastActivity = DispatchTime.now().uptimeNanoseconds
      do {
        switch event {
        case .headers(let value):
          guard response == nil else { throw YlDashProgramResources.error("network.response_invalid") }
          response = value
          if value.statusCode != 200 && value.statusCode != 206 { finished = true; return }
          if let encoding = value.value(forHTTPHeaderField: "Content-Encoding"), encoding.lowercased() != "identity" {
            throw YlDashProgramResources.error("network.response_invalid")
          }
          if let raw = value.value(forHTTPHeaderField: "Content-Length") {
            guard let length = Int64(raw), length >= 0 else { throw YlDashProgramResources.error("network.response_invalid") }
            guard length <= maximum else { throw YlDashProgramResources.error("resource.exhausted") }
            expectedLength = length
          }
          if let range {
            guard value.statusCode == 206,
                  let raw = value.value(forHTTPHeaderField: "Content-Range"), raw.hasPrefix("bytes ") else {
              throw YlDashProgramResources.error("network.range_invalid")
            }
            let parts = raw.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
            let bounds = parts.first?.split(separator: "-", omittingEmptySubsequences: false) ?? []
            guard parts.count == 2, bounds.count == 2,
                  let start = Int64(bounds[0]), let end = Int64(bounds[1]), let total = Int64(parts[1]),
                  start == range.start, end == start + (range.length - 1), total > end,
                  expectedLength == nil || expectedLength == range.length else {
              throw YlDashProgramResources.error("network.range_invalid")
            }
            expectedLength = range.length; resourceLength = total
          } else {
            guard value.statusCode == 200 else { throw YlDashProgramResources.error("network.range_invalid") }
            resourceLength = expectedLength
          }
        case .body(let bytes):
          guard response != nil else { throw YlDashProgramResources.error("network.response_invalid") }
          guard bytes.count <= maximum - data.count else { throw YlDashProgramResources.error("resource.exhausted") }
          data.append(bytes)
        case .complete(let error):
          if let error { throw error }
          guard response != nil, expectedLength == nil || expectedLength == Int64(data.count) else {
            throw YlDashProgramResources.error("network.response_invalid")
          }
          finished = true
        }
      } catch { failure = error; finished = true }
    }
    func wait(cancellation: YlOpenCancellationToken) throws {
      condition.lock(); defer { condition.unlock() }
      while !finished {
        try cancellation.throwIfCancelled()
        let timeout = response == nil ? configuration.connectTimeoutMs : configuration.readTimeoutMs
        if timeout > 0, DispatchTime.now().uptimeNanoseconds - lastActivity >= UInt64(timeout) * 1_000_000 {
          finished = true; throw YlDashProgramResources.error("network.timeout")
        }
        _ = condition.wait(until: Date(timeIntervalSinceNow: 0.02))
      }
      try cancellation.throwIfCancelled()
      if let failure { throw failure }
    }
  }
}
