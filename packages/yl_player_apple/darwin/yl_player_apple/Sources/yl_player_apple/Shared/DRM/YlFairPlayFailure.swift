import yl_player_media_core
import Foundation

enum YlFairPlayFailure {
  static let messages: [String: String] = [
    "load.cancelled": "The load was cancelled.",
    "drm.config_invalid": "The DRM configuration is invalid. Check the certificate and content identifier.",
    "drm.unsupported": "This device or playback route does not support the requested DRM configuration.",
    "drm.session_failed": "The system DRM session failed. Reload the source or check device support.",
    "drm.protection_insufficient": "The required content protection is unavailable. Check the device and protected output.",
    "drm.license_denied": "The license server refused the request. Check authorization and license request configuration.",
    "drm.license_expired": "The license has expired according to explicit DRM evidence. Renew authorization.",
    "drm.license_timeout": "The license request exceeded its deadline.",
    "drm.license_failed": "The license request failed. Check the connection and license service.",
    "drm.license_redirect_rejected": "The license redirect was rejected by the POST policy. Configure the final license endpoint.",
    "drm.payload_too_large": "The DRM request or response exceeds its byte limit.",
    "drm.license_response_invalid": "The license server returned an empty or unsupported response.",
  ]
  static var codes: Set<String> { Set(messages.keys) }
  static func error(_ code: String) -> NativePlayerError {
    let category: String
    switch code {
    case "load.cancelled": category = "cancelled"
    case "resource.exhausted": category = "resource"
    case "drm.config_invalid": category = "source"
    case "drm.unsupported": category = "unsupported"
    case "drm.license_denied", "drm.license_timeout", "drm.license_failed", "drm.license_redirect_rejected", "drm.license_response_invalid": category = "network"
    case "drm.payload_too_large": category = "resource"
    default: category = "platform"
    }
    return NativePlayerError(category: category, code: code,
      message: messages[code] ?? (code == "load.cancelled" ? "The load was cancelled." : "The DRM resource limit was reached. Reload the source."))
  }
  static func transport(_ error: NativePlayerError) -> NativePlayerError {
    let allowed: Set<String> = ["load.cancelled", "resource.exhausted", "drm.config_invalid", "drm.unsupported",
      "drm.license_denied", "drm.license_timeout", "drm.license_failed", "drm.license_redirect_rejected",
      "drm.payload_too_large", "drm.license_response_invalid"]
    return Self.error(allowed.contains(error.code) ? error.code : "drm.license_failed")
  }
}
