import Foundation
import CoreFoundation
import yl_player_media_core

/// Untrusted channel input. Both admission and preparation use this projection.
enum YlDeliveryWire {
  static func unsupported() -> NativePlayerError {
    NativePlayerError(category: "unsupported", code: "policy.unsupported", message: "The requested delivery policy is unsupported.")
  }
  static func invalid() -> NativePlayerError {
    NativePlayerError(category: "source", code: "source.invalid", message: "Invalid media delivery input.")
  }
  static func identifier(_ arguments: Any?) throws -> String {
    guard let map = arguments as? [String: Any], let id = map["id"] as? String,
          id.range(of: "^d[0-9]{1,18}$", options: .regularExpression) != nil else { throw invalid() }
    return id
  }
  private static func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }
  private static func zeroOrAbsent(_ value: Any?) -> Bool {
    if absent(value) { return true }
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue == 0 else { return false }
    return true
  }
  private static func headers(_ value: Any?) throws -> [String: String] {
    guard let values = value as? [String: String], values.count <= 128 else { throw invalid() }
    var bytes = 0
    for (name, value) in values {
      bytes += name.utf8.count + value.utf8.count
      guard bytes <= 64 * 1024 else { throw invalid() }
    }
    return values
  }
  static func input(_ arguments: Any?) throws -> YlMediaDeliveryInput {
    _ = try identifier(arguments)
    guard let map = arguments as? [String: Any], let source = map["source"] as? [String: Any],
          let options = map["options"] as? [String: Any], source["kind"] as? String == "network",
          let raw = source["uri"] as? String, raw.utf8.count <= 32 * 1024,
          let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
          let host = url.host, !host.isEmpty,
          url.user == nil, url.password == nil, url.fragment == nil,
          let intent = source["intent"] as? String, ["automatic", "live", "onDemand"].contains(intent),
          let format = source["format"] as? String,
          let policy = source["networkPolicy"] as? [String: Any],
          let buffer = options["bufferStrategy"] as? [String: Any] else { throw invalid() }
    guard intent != "onDemand", absent(source["drm"]),
          policy["kind"] as? String == "platformDefault",
          ["connectTimeoutMs", "readTimeoutMs", "maxRetries", "baseRetryDelayMs", "maxRetryDelayMs", "maxRedirects"].allSatisfy({ absent(policy[$0]) }),
          zeroOrAbsent(options["startPositionMs"]),
          ["maxWidth", "maxHeight", "maxBitrate"].allSatisfy({ absent(options[$0]) }),
          ["automatic", "smoothPlayback"].contains(buffer["kind"] as? String ?? ""),
          ["minDurationMs", "maxDurationMs", "maxManagedBytes"].allSatisfy({ absent(buffer[$0]) })
    else { throw unsupported() }
    guard ["automatic", "flv"].contains(format) else {
      throw YlAirPlayRemux.failure("unsupported_source", "Live delivery requires FLV.")
    }
    // Match the player boundary: credentials must be explicitly classified so
    // the shared request policy can strip them after an origin change.
    let ordinary = try headers(source["headers"])
    let credentials = try headers(source["credentials"])
    do { try YlHttpHeaderAdmission.validate(headers: ordinary, credentials: credentials) }
    catch { throw invalid() }
    let scope = try YlManagedBufferLedger().makeScope(maxBytes: nil)
    let recipe: YlFallbackSourceRecipe
    switch scheme {
    case "rtmp", "rtmps":
      guard ordinary.isEmpty, credentials.isEmpty else { throw unsupported() }
      recipe = .rtmp(request: YlRtmpRequestRecipe(address: try YlRtmpAddress(raw),
        recovery: YlRtmpRecoveryBudget(), bufferScope: scope))
    case "http", "https":
      guard format == "flv" || url.pathExtension.lowercased() == "flv" else {
        throw YlAirPlayRemux.failure("unsupported_source", "HTTP delivery requires FLV.")
      }
      recipe = .network(request: YlNetworkRequestRecipe(url: url, headers: ordinary, credentials: credentials,
        configuration: YlNetworkConfiguration(map: [:]), mode: .sequentialLive, bufferScope: scope), container: .flv)
    default: throw YlAirPlayRemux.failure("unsupported_source", "Delivery requires HTTP-FLV, RTMP or RTMPS.")
    }
    return YlMediaDeliveryInput(recipe: recipe, isLive: true)
  }
}
