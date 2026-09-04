import AVFoundation
import Foundation

struct YlAvPlayerErrorLogSnapshot {
  let domain: String?
  let statusCode: Int?
  let uri: String?
}

enum YlAvPlayerRecoveryPolicy {
  static func shouldReconnect(
    source: [String: Any?],
    usesResourceLoader: Bool,
    hasBeenReady: Bool,
    playRequested: Bool,
    error: NSError?,
    errorLogDomain: String?,
    errorLogStatusCode: Int?
  ) -> Bool {
    guard isDirectLiveHls(source, usesResourceLoader: usesResourceLoader),
          playRequested || !hasBeenReady else {
      return false
    }
    return isTransient(
      error: error,
      errorLogDomain: errorLogDomain,
      errorLogStatusCode: errorLogStatusCode
    )
  }

  static func diagnostic(
    error: NSError?,
    errorDomain: String?,
    statusCode: Int?,
    uri: String?
  ) -> String {
    let outerDomain = safeDomain(error?.domain) ?? "unknown"
    let outerCode = error.map { String($0.code) } ?? "unknown"
    let base = "NSError(domain=\(outerDomain), code=\(outerCode))"
    guard errorDomain != nil || statusCode != nil || uri != nil else { return base }

    var fields: [String] = []
    if let errorDomain {
      fields.append("domain=\(safeDomain(errorDomain) ?? "unknown")")
    }
    if let statusCode {
      fields.append("status=\(statusCode)")
    }
    if let uri, let sanitizedURI = sanitized(uri) {
      fields.append("uri=\(sanitizedURI)")
    }
    return "\(base); HLS(\(fields.joined(separator: ", ")))"
  }

  private static func isDirectLiveHls(
    _ source: [String: Any?],
    usesResourceLoader: Bool
  ) -> Bool {
    guard source["kind"] as? String == "network",
          source["isLive"] as? Bool == true,
          !usesResourceLoader,
          let uri = source["uri"] as? String,
          let url = URL(string: uri) else {
      return false
    }
    let formatHint = source["formatHint"] as? String ?? "automatic"
    return formatHint == "hls"
      || (formatHint == "automatic" && url.pathExtension.lowercased() == "m3u8")
  }

  private static func isTransient(
    error: NSError?,
    errorLogDomain: String?,
    errorLogStatusCode: Int?
  ) -> Bool {
    var current = error
    for _ in 0..<8 {
      guard let candidate = current else { break }
      if candidate.domain == NSURLErrorDomain,
         transientURLErrorCodes.contains(candidate.code) {
        return true
      }
      if candidate.domain == AVFoundationErrorDomain,
         candidate.code == AVError.mediaServicesWereReset.rawValue {
        return true
      }
      if candidate.domain == "CoreMediaErrorDomain", candidate.code == -12312 {
        return true
      }
      current = candidate.userInfo[NSUnderlyingErrorKey] as? NSError
    }

    guard let errorLogStatusCode else { return false }
    if errorLogDomain == "CoreMediaErrorDomain" && errorLogStatusCode == -12312 {
      return true
    }
    guard errorLogDomain == "CoreMediaErrorDomain" else { return false }
    return errorLogStatusCode == 408
      || errorLogStatusCode == 429
      || (500...599).contains(errorLogStatusCode)
  }

  private static func safeDomain(_ domain: String?) -> String? {
    guard let domain else { return nil }
    switch domain {
    case NSURLErrorDomain, AVFoundationErrorDomain, "CoreMediaErrorDomain":
      return domain
    default:
      return "other"
    }
  }

  private static func sanitized(_ uri: String) -> String? {
    guard var components = URLComponents(string: uri) else { return nil }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.string
  }

  private static let transientURLErrorCodes: Set<Int> = [
    NSURLErrorTimedOut,
    NSURLErrorCannotFindHost,
    NSURLErrorCannotConnectToHost,
    NSURLErrorNetworkConnectionLost,
    NSURLErrorDNSLookupFailed,
    NSURLErrorResourceUnavailable,
    NSURLErrorNotConnectedToInternet,
    NSURLErrorInternationalRoamingOff,
    NSURLErrorCallIsActive,
    NSURLErrorDataNotAllowed,
  ]
}

/// Reads potentially blocking AVPlayer logs without serializing unrelated item
/// generations, and bounds how long playback waits for diagnostic metadata.
final class YlAvPlayerErrorLogCollector {
  private let queue = DispatchQueue(
    label: "dev.ylplayer.avplayer-error-log",
    qos: .utility,
    attributes: .concurrent
  )
  private let callbackQueue: DispatchQueue

  init(callbackQueue: DispatchQueue = .main) {
    self.callbackQueue = callbackQueue
  }

  func collect(
    timeoutMs: Int64,
    read: @escaping () -> YlAvPlayerErrorLogSnapshot,
    completion: @escaping (YlAvPlayerErrorLogSnapshot?) -> Void
  ) {
    let delivery = YlAvPlayerOneShotDelivery()
    queue.async { [callbackQueue] in
      let snapshot = read()
      guard delivery.claim() else { return }
      callbackQueue.async { completion(snapshot) }
    }
    queue.asyncAfter(
      deadline: .now() + .milliseconds(Int(max(0, min(timeoutMs, 60_000))))
    ) { [callbackQueue] in
      guard delivery.claim() else { return }
      callbackQueue.async { completion(nil) }
    }
  }
}

private final class YlAvPlayerOneShotDelivery {
  private let lock = NSLock()
  private var delivered = false

  func claim() -> Bool {
    lock.withLock {
      guard !delivered else { return false }
      delivered = true
      return true
    }
  }
}

/// Coalesces AVPlayer's KVO and notification failure callbacks per item.
final class YlAvPlayerFailureGate {
  private var processingGeneration: UInt64?
  private var terminalGeneration: UInt64?

  func begin(generation: UInt64) -> Bool {
    guard processingGeneration != generation,
          terminalGeneration != generation else {
      return false
    }
    processingGeneration = generation
    return true
  }

  func finish(generation: UInt64, currentGeneration: UInt64) -> Bool {
    guard processingGeneration == generation else { return false }
    processingGeneration = nil
    return generation == currentGeneration
  }

  func markTerminal(generation: UInt64) {
    terminalGeneration = generation
  }

  func reset() {
    processingGeneration = nil
    terminalGeneration = nil
  }
}
