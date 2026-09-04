import Foundation

enum YlHlsURLCodec {
  static let scheme = "ylhls"
  private static let host = "resource"

  static func encode(_ destination: URL) throws -> URL {
    try validateHTTPDestination(destination)
    let payload = Data(destination.absoluteString.utf8)
      .base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    guard let encoded = URL(string: "\(scheme)://\(host)/\(payload)") else {
      throw invalidURL("The internal HLS resource URL could not be encoded.")
    }
    return encoded
  }

  static func decode(_ encoded: URL) throws -> URL {
    guard encoded.scheme?.lowercased() == scheme,
          encoded.host?.lowercased() == host else {
      throw invalidURL("The internal HLS resource URL is invalid.")
    }
    let payload = String(encoded.path.drop(while: { $0 == "/" }))
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
