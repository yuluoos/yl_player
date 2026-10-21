import Foundation

public struct NativePlayerError: Error, CustomStringConvertible, CustomDebugStringConvertible {
  public let category: String
  public let code: String
  public let message: String
  public var diagnostic: String?

  public var description: String { "Playback operation failed." }
  public var debugDescription: String { description }

  public init(category: String, code: String, message: String, diagnostic: String? = nil) {
    self.category = category
    self.code = code
    self.message = message
    self.diagnostic = diagnostic
  }
}

/// Status is encoded in a bounded package-owned code so it survives both native
/// and Dart sanitization without forwarding response bodies or reason phrases.
public enum YlHTTPFailure {
  public static func status(from code: String) -> Int? {
    if code == "network.http_forbidden" { return 403 }
    let prefix = "network.http_status."
    guard code.hasPrefix(prefix) else { return nil }
    let suffix = String(code.dropFirst(prefix.count))
    guard suffix.count == 3, let status = Int(suffix), (100...599).contains(status),
      suffix == String(status) else { return nil }
    return status
  }

  public static func message(status: Int) -> String {
    let reason: String
    switch status {
    case 401: reason = "The media server requires authentication. Check access credentials."
    case 403: reason = "The media server refused the request. Check access credentials and request configuration."
    case 404: reason = "The requested media resource was not found."
    case 408: reason = "The media server timed out waiting for the request."
    case 410: reason = "The requested media resource is no longer available."
    case 416: reason = "The media server rejected the requested byte range."
    case 429: reason = "Too many requests. Wait before retrying."
    case 500...599: reason = "The upstream media service is unavailable or failed to complete the request."
    case 300...399: reason = "The media redirect could not be followed."
    default: reason = "The media server returned an unexpected HTTP response."
    }
    return "HTTP \(status): \(reason)"
  }

  public static func error(status: Int) -> NativePlayerError {
    guard (100...599).contains(status) else {
      return NativePlayerError(category: "network", code: "network.response_invalid",
        message: "The media server returned an invalid response.")
    }
    return NativePlayerError(category: "network",
      code: status == 403 ? "network.http_forbidden" : "network.http_status.\(status)",
      message: message(status: status), diagnostic: "HTTP \(status) network.request")
  }
}
