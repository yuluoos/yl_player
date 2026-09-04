import AVFoundation
import Foundation

enum YlAvPlayerFailurePolicy {
  static func diagnostic(_ error: NSError?) -> String {
    let domain: String
    switch error?.domain {
    case NSURLErrorDomain:
      domain = "NSURLErrorDomain"
    case AVFoundationErrorDomain:
      domain = "AVFoundationErrorDomain"
    case "CoreMediaErrorDomain":
      domain = "CoreMediaErrorDomain"
    case .some:
      domain = "other"
    case nil:
      domain = "unknown"
    }
    let code = error.map { String($0.code) } ?? "unknown"
    return "NSError(domain=\(domain), code=\(code))"
  }
}

/// Coalesces AVPlayer KVO and playback-end notifications for one item.
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
