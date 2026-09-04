import Foundation

enum YlHlsResourceKind: String {
  case manifest
  case key
  case media
}

enum YlHlsURLCodec {
  static let scheme = "ylhls"
  private static let host = "resource"

  static func encode(
    _ destination: URL,
    kind: YlHlsResourceKind? = nil
  ) throws -> URL {
    try validateHTTPDestination(destination)
    let payload = Data(destination.absoluteString.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    let resourceKind = kind ?? inferredKind(for: destination)
    components.path = "/\(payload)/\(resourceKind.rawValue)/\(resourceName(for: destination))"
    guard let encoded = components.url else {
      throw invalidURL("The internal HLS resource URL could not be encoded.")
    }
    return encoded
  }

  static func resourceKind(_ encoded: URL) throws -> YlHlsResourceKind {
    _ = try decode(encoded)
    let components = Array(encoded.pathComponents.dropFirst())
    guard components.count >= 2,
          let kind = YlHlsResourceKind(rawValue: components[1]) else {
      throw invalidURL("The internal HLS resource kind is invalid.")
    }
    return kind
  }

  static func decode(_ encoded: URL) throws -> URL {
    guard encoded.scheme?.lowercased() == scheme,
          encoded.host?.lowercased() == host else {
      throw invalidURL("The internal HLS resource URL is invalid.")
    }
    let payload = encoded.pathComponents.dropFirst().first ?? ""
    guard !payload.isEmpty else {
      throw invalidURL("The internal HLS resource URL has no destination.")
    }
    var base64 = payload
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    guard let data = Data(base64Encoded: base64),
          let value = String(data: data, encoding: .utf8),
          let destination = URL(string: value) else {
      throw invalidURL("The internal HLS resource destination is invalid.")
    }
    try validateHTTPDestination(destination)
    return destination
  }

  private static func resourceName(for destination: URL) -> String {
    let name = destination.lastPathComponent
    return name.isEmpty ? "resource" : name
  }

  static func inferredKind(for destination: URL) -> YlHlsResourceKind {
    destination.pathExtension.lowercased() == "m3u8" ? .manifest : .media
  }

  private static func validateHTTPDestination(_ url: URL) throws {
    guard let destinationScheme = url.scheme?.lowercased(),
          destinationScheme == "http" || destinationScheme == "https",
          url.host?.isEmpty == false else {
      throw invalidURL("HLS resources must use HTTP or HTTPS URLs.")
    }
  }

  private static func invalidURL(_ message: String) -> NativePlayerError {
    NativePlayerError(
      category: "container",
      code: "container.hls_url_invalid",
      message: message
    )
  }
}
