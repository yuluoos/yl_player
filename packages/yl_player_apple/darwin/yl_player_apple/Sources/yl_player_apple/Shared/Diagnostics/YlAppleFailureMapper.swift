import Foundation

/// Explicit private Pigeon names preserve the public protocol/internal categories.
enum YlAppleFailureMapper {
  static func category(_ native: String) -> AppleFailureCategory {
    switch native {
    case "cancelled": .cancelled
    case "unsupported": .unsupported
    case "source": .source
    case "network": .network
    case "container": .container
    case "decoder", "decoderUnsupported", "decoderFailure": .decoder
    case "render": .render
    case "resource": .resource
    case "protocol": .protocolFailure
    case "platform": .platform
    case "internal": .internalFailure
    default: .internalFailure
    }
  }
}

extension YlAppleFailureMapper {
  static func message(_ error: Error, scope: AppleFailureScope) -> AppleFailureMessage {
    let native = error as? NativePlayerError
    let code = native?.code ?? "platform.failure"
    let safeCode = code.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil
      ? code : "platform.failure"
    return AppleFailureMessage(category: category(native?.category ?? "internal"),
      code: safeCode, message: "Playback operation failed.", retryable: false,
      scope: scope, diagnosticId: YlAppleSafeDiagnostics.identifier())
  }
  static func command(_ error: Error) -> PigeonError {
    if let failure = error as? PigeonError { return failure }
    let failure = message(error, scope: .command)
    return PigeonError(code: failure.code, message: failure.message, details: failure)
  }
  static func invalid(_ code: String = "source.invalid_argument") -> NativePlayerError {
    NativePlayerError(category: "source", code: code, message: "Playback argument is invalid.")
  }
  static var unsupported: NativePlayerError {
    NativePlayerError(category: "unsupported", code: "policy.unsupported", message: "Playback policy is unsupported.")
  }
}
