import Foundation

enum YlSourceRouter {
  private static let fallbackHints: Set<String> = [
    "httpFlv", "flv", "matroska", "webm", "mpegTs", "mpegPs", "avi",
  ]

  private static let fallbackExtensions: Set<String> = [
    "flv", "mkv", "webm", "ts", "m2ts", "mpg", "mpeg", "ps", "avi",
  ]

  // Initial activation, validation and rollback must use the same effective
  // HTTP request context, including credentials kept separate from headers.
  static func route(_ source: [String: Any?]) -> YlMacosSourceRoute {
    let headers = stringMap(source["headers"]).compactMapValues { $0 as? String }
    let credentials = stringMap(source["credentials"]).compactMapValues { $0 as? String }
    return route(YlMacosSourceDescriptor(
      uri: source["uri"] as? String ?? "",
      kind: source["kind"] as? String ?? "",
      formatHint: source["formatHint"] as? String ?? "automatic",
      isLive: source["isLive"] as? Bool ?? false,
      hasHeaders: !headers.isEmpty || !credentials.isEmpty
    ))
  }

  static func route(_ source: YlMacosSourceDescriptor) -> YlMacosSourceRoute {
    guard let url = validatedUrl(for: source) else {
      return .reject(
        category: "source",
        code: "source.invalid_uri",
        message: "A valid media URI is required."
      )
    }

    let isLocalMatroska = source.kind == "file"
      && (source.formatHint == "matroska"
        || (source.formatHint == "automatic" && url.pathExtension.lowercased() == "mkv"))
    if isLocalMatroska {
      return .localMatroska
    }

    let isNetworkMatroska = source.kind == "network"
      && (source.formatHint == "matroska"
        || (source.formatHint == "automatic" && url.pathExtension.lowercased() == "mkv"))
    if isNetworkMatroska {
      if source.isLive {
        return .reject(
          category: "container",
          code: "container.network_mkv_live_unsupported",
          message: "Network Matroska live playback is not supported."
        )
      }
      return .networkMatroska
    }

    let isNetworkFlv = source.kind == "network"
      && (source.formatHint == "httpFlv"
        || source.formatHint == "flv"
        || (source.formatHint == "automatic" && url.pathExtension.lowercased() == "flv"))
    if isNetworkFlv {
      return .networkFlv
    }

    let isHls = source.kind == "network"
      && (source.formatHint == "hls"
        || (source.formatHint == "automatic" && url.pathExtension.lowercased() == "m3u8"))
    if isHls && source.hasHeaders {
      return .headeredHls
    }

    if source.hasHeaders {
      return .reject(
        category: "container",
        code: "container.headers_require_fallback",
        message: "Custom macOS HTTP headers require a compatible native fallback route."
      )
    }

    if fallbackHints.contains(source.formatHint)
      || (source.formatHint == "automatic"
        && fallbackExtensions.contains(url.pathExtension.lowercased())) {
      return .reject(
        category: "container",
        code: "container.native_fallback_required",
        message: "This source requires a macOS native fallback that is not implemented."
      )
    }

    return .avPlayer
  }

  private static func validatedUrl(for source: YlMacosSourceDescriptor) -> URL? {
    guard !source.uri.isEmpty, let url = URL(string: source.uri), url.scheme != nil else {
      return nil
    }
    switch source.kind {
    case "file":
      return url.isFileURL ? url : nil
    case "network":
      return url.scheme == "http" || url.scheme == "https" ? url : nil
    case "content":
      return url.scheme == "content" ? url : nil
    default:
      return nil
    }
  }
}
