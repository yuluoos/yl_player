import Foundation

enum YlHlsManifestRewriter {
  private static let uriAttribute = try! NSRegularExpression(
    pattern: #"\bURI="([^"]*)""#,
    options: [.caseInsensitive]
  )

  static func rewrite(data: Data, baseURL: URL) throws -> Data {
    guard let manifest = String(data: data, encoding: .utf8) else {
      throw invalidManifest("The HLS manifest is not valid UTF-8.")
    }
    let hasMarker = manifest == "#EXTM3U"
      || manifest.hasPrefix("#EXTM3U\r\n")
      || manifest.hasPrefix("#EXTM3U\n")
      || manifest.hasPrefix("#EXTM3U\r")
    guard hasMarker else {
      throw invalidManifest("The HLS manifest is missing the EXTM3U marker.")
    }

    var output = ""
    var lineStart = manifest.startIndex
    var cursor = manifest.startIndex
    while cursor < manifest.endIndex {
      if manifest[cursor] == "\r" || manifest[cursor] == "\n" {
        let line = String(manifest[lineStart..<cursor])
        output += try rewrite(line: line, baseURL: baseURL)
        if manifest[cursor] == "\r" {
          let next = manifest.index(after: cursor)
          if next < manifest.endIndex, manifest[next] == "\n" {
            output += "\r\n"
            cursor = next
          } else {
            output += "\r"
          }
        } else {
          output += "\n"
        }
        cursor = manifest.index(after: cursor)
        lineStart = cursor
      } else {
        cursor = manifest.index(after: cursor)
      }
    }
    if lineStart < manifest.endIndex {
      output += try rewrite(line: String(manifest[lineStart...]), baseURL: baseURL)
    }
    return Data(output.utf8)
  }

  private static func rewrite(line: String, baseURL: URL) throws -> String {
    let leading = line.prefix { $0.isWhitespace }
    let trailing = line.reversed().prefix { $0.isWhitespace }.reversed()
    let contentStart = line.index(line.startIndex, offsetBy: leading.count)
    let contentEnd = line.index(line.endIndex, offsetBy: -trailing.count)
    guard contentStart < contentEnd else { return line }
    let content = String(line[contentStart..<contentEnd])

    if !content.hasPrefix("#") {
      return String(leading)
        + (try rewrite(uri: content, baseURL: baseURL))
        + String(trailing)
    }

    var rewritten = content
    let fullRange = NSRange(rewritten.startIndex..., in: rewritten)
    let matches = uriAttribute.matches(in: rewritten, range: fullRange)
    for match in matches.reversed() {
      guard match.numberOfRanges == 2,
            let valueRange = Range(match.range(at: 1), in: rewritten) else {
        continue
      }
      let value = String(rewritten[valueRange])
      let replacement = try rewrite(uri: value, baseURL: baseURL)
      rewritten.replaceSubrange(valueRange, with: replacement)
    }
    return String(leading) + rewritten + String(trailing)
  }

  private static func rewrite(uri: String, baseURL: URL) throws -> String {
    guard !uri.isEmpty,
          let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
      throw invalidManifest("The HLS manifest contains an invalid URI.")
    }
    guard let scheme = resolved.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      return uri
    }
    do {
      return try YlHlsURLCodec.encode(resolved).absoluteString
    } catch {
      throw invalidManifest("The HLS manifest contains an invalid HTTP resource URI.")
    }
  }

  private static func invalidManifest(_ message: String) -> NativePlayerError {
    NativePlayerError(
      category: "container",
      code: "container.hls_manifest_invalid",
      message: message
    )
  }
}
