import Foundation

enum YlHlsManifestRewriter {
  private static let uriAttribute = try! NSRegularExpression(
    pattern: #"\bURI="([^"]*)""#,
    options: [.caseInsensitive]
  )

  static func rewrite(
    data: Data,
    baseURL: URL,
    mediaURL: ((URL) throws -> URL)? = nil
  ) throws -> Data {
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
    var pendingPlainKind: YlHlsResourceKind?
    func rewriteManifestLine(_ line: String) throws -> String {
      let rewritten = try rewrite(
        line: line,
        baseURL: baseURL,
        plainKind: pendingPlainKind,
        mediaURL: mediaURL
      )
      let content = line.trimmingCharacters(in: .whitespaces)
      if content.uppercased().hasPrefix("#EXT-X-STREAM-INF:") {
        pendingPlainKind = .manifest
      } else if content.uppercased().hasPrefix("#EXTINF:") {
        pendingPlainKind = .media
      } else if !content.isEmpty && !content.hasPrefix("#") {
        pendingPlainKind = nil
      }
      return rewritten
    }
    while cursor < manifest.endIndex {
      if manifest[cursor] == "\r" || manifest[cursor] == "\n" {
        let line = String(manifest[lineStart..<cursor])
        output += try rewriteManifestLine(line)
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
      output += try rewriteManifestLine(String(manifest[lineStart...]))
    }
    return Data(output.utf8)
  }

  private static func rewrite(
    line: String,
    baseURL: URL,
    plainKind: YlHlsResourceKind?,
    mediaURL: ((URL) throws -> URL)?
  ) throws -> String {
    let leading = line.prefix { $0.isWhitespace }
    let trailing = line.reversed().prefix { $0.isWhitespace }.reversed()
    let contentStart = line.index(line.startIndex, offsetBy: leading.count)
    let contentEnd = line.index(line.endIndex, offsetBy: -trailing.count)
    guard contentStart < contentEnd else { return line }
    let content = String(line[contentStart..<contentEnd])

    if !content.hasPrefix("#") {
      return String(leading)
        + (try rewrite(
          uri: content,
          baseURL: baseURL,
          kind: plainKind,
          mediaURL: mediaURL
        ))
        + String(trailing)
    }

    var rewritten = content
    let uppercased = content.uppercased()
    let explicitKind = resourceKind(forTag: uppercased)
    let fullRange = NSRange(rewritten.startIndex..., in: rewritten)
    let matches = uriAttribute.matches(in: rewritten, range: fullRange)
    for match in matches.reversed() {
      guard match.numberOfRanges == 2,
            let valueRange = Range(match.range(at: 1), in: rewritten) else {
        continue
      }
      let value = String(rewritten[valueRange])
      let replacement = try rewrite(
        uri: value,
        baseURL: baseURL,
        kind: explicitKind,
        mediaURL: mediaURL
      )
      rewritten.replaceSubrange(valueRange, with: replacement)
    }
    return String(leading) + rewritten + String(trailing)
  }

  private static func resourceKind(forTag tag: String) -> YlHlsResourceKind? {
    if tag.hasPrefix("#EXT-X-KEY:") || tag.hasPrefix("#EXT-X-SESSION-KEY:") {
      return .key
    }
    if tag.hasPrefix("#EXT-X-MEDIA:")
      || tag.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:")
      || tag.hasPrefix("#EXT-X-IMAGE-STREAM-INF:")
      || tag.hasPrefix("#EXT-X-RENDITION-REPORT:") {
      return .manifest
    }
    if tag.hasPrefix("#EXT-X-MAP:")
      || tag.hasPrefix("#EXT-X-PART:")
      || tag.hasPrefix("#EXT-X-PRELOAD-HINT:") {
      return .media
    }
    return nil
  }

  private static func rewrite(
    uri: String,
    baseURL: URL,
    kind: YlHlsResourceKind?,
    mediaURL: ((URL) throws -> URL)?
  ) throws -> String {
    guard !uri.isEmpty,
          let resolved = URL(string: uri, relativeTo: baseURL)?.absoluteURL else {
      throw invalidManifest("The HLS manifest contains an invalid URI.")
    }
    guard let scheme = resolved.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      return uri
    }
    do {
      let resourceKind = kind ?? YlHlsURLCodec.inferredKind(for: resolved)
      if resourceKind == .media, let mediaURL {
        return try mediaURL(resolved).absoluteString
      }
      return try YlHlsURLCodec.encode(
        resolved,
        kind: resourceKind
      ).absoluteString
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
