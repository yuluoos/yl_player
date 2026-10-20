import Foundation

/// Shared request-metadata admission for playback and independent delivery.
/// Credentials are classified explicitly so origin changes can strip them.
public enum YlHttpHeaderAdmission {
  public static func validate(headers: [String: String], credentials: [String: String]) throws {
    var seen = Set<String>()
    let tokens = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
    for (values, isCredential) in [(headers, false), (credentials, true)] {
      for (name, value) in values {
        let lower = name.lowercased()
        guard !name.isEmpty, name.unicodeScalars.allSatisfy({ tokens.contains($0) }),
          value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127) }),
          !["host", "content-length", "connection", "transfer-encoding", "range", "if-range"].contains(lower),
          seen.insert(lower).inserted,
          isCredential || lower.range(of: "auth|cookie|token|key|secret|credential", options: .regularExpression) == nil else {
          throw NativePlayerError(category: "source", code: "source.invalid_argument",
            message: "Request metadata is invalid.")
        }
      }
    }
  }
}
