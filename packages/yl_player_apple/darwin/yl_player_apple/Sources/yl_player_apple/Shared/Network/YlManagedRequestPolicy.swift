import Foundation

/// Shared by the original resource intent, including inspection and internal
/// reopen. Cancellation retires a reader, not this budget. A completed resource
/// permits a distinct recovery request; terminal failures cannot be reopened.
final class YlManagedRequestIntent {
  private let lock = NSLock()
  private var retries = 0
  private var redirects = 0
  private var failure: NativePlayerError?

  var terminalFailure: NativePlayerError? {
    lock.lock(); defer { lock.unlock() }; return failure
  }
  func fail(_ error: NativePlayerError) {
    lock.lock(); defer { lock.unlock() }; if failure == nil { failure = error }
  }
  func completed() {
    lock.lock(); defer { lock.unlock() }
    guard failure == nil else { return }
    retries = 0; redirects = 0
  }
  func followRedirect(maximum: Int) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard failure == nil, redirects < maximum else { return false }
    redirects += 1; return true
  }
  func nextRetry(maximum: Int) -> Int? {
    lock.lock(); defer { lock.unlock() }
    guard failure == nil, retries < maximum else { return nil }
    retries += 1; return retries
  }
}

/// Sole timer owner for a byte reader. Connect covers each attempt/hop through
/// response headers; read covers body inactivity. No overall load deadline.
/// Injected scheduling/time make transition and HTTP-date tests deterministic.
final class YlManagedRequestPolicy {
  typealias Schedule = (Int64, @escaping () -> Void) -> (() -> Void)
  private let lock = NSLock()
  private let schedule: Schedule
  private let now: () -> Date
  private var generation: UInt64 = 0
  private var cancelScheduled: (() -> Void)?

  init(now: @escaping () -> Date = Date.init, schedule: Schedule? = nil) {
    self.now = now
    self.schedule = schedule ?? { milliseconds, action in
      let item = DispatchWorkItem(block: action)
      let seconds = Double(milliseconds) / 1_000
      let deadline: DispatchTime = seconds >= Double(Int.max) / 1_000_000_000 ? .distantFuture : .now() + seconds
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline, execute: item)
      return { item.cancel() }
    }
  }

  func arm(after milliseconds: Int64, action: @escaping () -> Void) {
    lock.lock()
    generation &+= 1
    let expected = generation
    cancelScheduled?()
    cancelScheduled = schedule(milliseconds) { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let current = self.generation == expected
      self.lock.unlock()
      if current { action() }
    }
    lock.unlock()
  }

  func cancel() {
    lock.lock(); defer { lock.unlock() }
    generation &+= 1
    cancelScheduled?(); cancelScheduled = nil
  }
  deinit { cancel() }

  func retryDelay(attempt: Int, configuration: YlNetworkConfiguration, retryAfter: String?) -> Int64? {
    let cap = configuration.maxRetryDelayMs
    if let raw = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
      let seconds: Double?
      if raw.allSatisfy({ $0.isASCII && $0.isNumber }) {
        seconds = Double(raw) ?? .infinity
      } else {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        var parsed: Date?
        for format in ["EEE',' dd MMM yyyy HH':'mm':'ss z", "EEEE',' dd-MMM-yy HH':'mm':'ss z", "EEE MMM d HH':'mm':'ss yyyy"] {
          formatter.dateFormat = format
          if let date = formatter.date(from: raw) { parsed = date; break }
        }
        seconds = parsed.map { max(0, $0.timeIntervalSince(now())) }
      }
      if let seconds {
        let milliseconds = (seconds * 1_000).rounded(.up)
        guard milliseconds.isFinite, milliseconds <= Double(cap), milliseconds < Double(Int64.max) else { return nil }
        return Int64(milliseconds)
      }
    }
    var delay = min(configuration.baseRetryDelayMs, cap)
    if delay == 0 { return 0 }
    for _ in 1..<max(1, attempt) {
      if delay >= cap || delay > Int64.max / 2 { return cap }
      delay = min(cap, delay * 2)
    }
    return delay
  }

  static func isRetryableStatus(_ status: Int) -> Bool {
    [408, 429, 500, 502, 503, 504].contains(status)
  }
  static func isTransient(_ error: Error, method: String = "GET") -> Bool {
    guard ["GET", "HEAD"].contains(method.uppercased()) else { return false }
    let value = error as NSError
    guard value.domain == NSURLErrorDomain else { return false }
    return [URLError.Code.timedOut, .cannotFindHost, .cannotConnectToHost,
      .networkConnectionLost, .dnsLookupFailed, .resourceUnavailable,
      .notConnectedToInternet, .internationalRoamingOff, .callIsActive, .dataNotAllowed]
      .contains(URLError.Code(rawValue: value.code))
  }
}
