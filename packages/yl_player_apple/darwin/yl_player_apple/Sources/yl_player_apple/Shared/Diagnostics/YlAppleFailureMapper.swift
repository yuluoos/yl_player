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
    YlAppleSafeDiagnostics.failure(error, scope: scope)
  }
  static func command(_ error: Error) -> PigeonError {
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
