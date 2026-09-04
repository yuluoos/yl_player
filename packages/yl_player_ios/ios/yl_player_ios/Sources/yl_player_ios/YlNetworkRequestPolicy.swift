import Foundation

enum YlNetworkInputMode: Equatable {
  case randomAccessVOD
  case sequentialLive
}

struct YlNetworkRequestRecipe {
  let url: URL
  let headers: [String: String]
  let configuration: YlNetworkConfiguration
  let mode: YlNetworkInputMode

  init(
    url: URL,
    headers: [String: String],
    configuration: YlNetworkConfiguration,
    mode: YlNetworkInputMode = .randomAccessVOD
  ) {
    self.url = url
    self.headers = headers
    self.configuration = configuration
    self.mode = mode
  }
}

struct YlNetworkResponseMetadata: Equatable {
  let responseStart: Int64
  let resourceLength: Int64?
  let supportsRandomAccess: Bool
  let etag: String?
  let lastModified: String?
  let isEOF: Bool
}

final class YlNetworkRequestPolicy {
  private let recipe: YlNetworkRequestRecipe
  private let lock = NSLock()
  private var currentOffset: Int64 = 0
  private var currentValidator: YlNetworkResponseMetadata?
  private var redirectCount = 0

  init(recipe: YlNetworkRequestRecipe) {
    self.recipe = recipe
  }

  func request(
    offset: Int64,
    validator: YlNetworkResponseMetadata?
  ) throws -> URLRequest {
    guard offset >= 0 else {
      throw rangeInvalid("Negative byte offset")
    }
    guard recipe.mode == .randomAccessVOD || offset == 0 else {
      throw rangeNotSupported()
    }
    try Self.validateHTTPURL(recipe.url)
    lock.lock()
    currentOffset = offset
    currentValidator = validator
    redirectCount = 0
    lock.unlock()
    return makeRequest(
      url: recipe.url,
      headers: recipe.headers,
      offset: offset,
      validator: validator
    )
  }

  func redirectRequest(
    from sourceURL: URL,
    response: HTTPURLResponse,
    to destinationURL: URL
  ) throws -> URLRequest {
    _ = response
    _ = sourceURL
    do {
      try Self.validateHTTPURL(destinationURL)
    } catch let error as NativePlayerError {
      throw error
    }

    lock.lock()
    redirectCount += 1
    let count = redirectCount
    let offset = currentOffset
    let validator = currentValidator
    lock.unlock()

    guard count <= recipe.configuration.maxRedirects else {
      throw NativePlayerError(
        category: "network",
        code: "network.redirect_limit",
        message: "The network redirect limit was exceeded.",
        diagnostic: Self.sanitized(destinationURL)
      )
    }

    let destinationIsOriginalOrigin = Self.sameOrigin(recipe.url, destinationURL)
    let headers = recipe.headers.filter { name, _ in
      destinationIsOriginalOrigin
        || !Self.credentialHeaderNames.contains(name.lowercased())
    }
    return makeRequest(
      url: destinationURL,
      headers: headers,
      offset: offset,
      validator: validator
    )
  }

  func validate(
    response: HTTPURLResponse,
    requestedOffset: Int64
  ) throws -> YlNetworkResponseMetadata {
    guard requestedOffset >= 0 else {
      throw rangeInvalid("Negative byte offset")
    }
    let status = response.statusCode
    switch status {
    case 206:
      let range = try parsePartialContentRange(
        response.value(forHTTPHeaderField: "Content-Range")
      )
      guard range.start == requestedOffset else {
        throw rangeInvalid("Content-Range start did not match requested offset")
      }
      if let contentLength = try parseContentLength(response),
         contentLength != range.length {
        throw rangeInvalid("Content-Length did not match Content-Range")
      }
      let metadata = metadata(
        response: response,
        start: range.start,
        length: range.total,
        randomAccess: recipe.mode == .randomAccessVOD,
        isEOF: false
      )
      try validateRepresentation(metadata)
      return metadata

    case 200:
      guard requestedOffset == 0 else {
        if snapshotValidator() != nil {
          throw contentChanged(response.url)
        }
        throw NativePlayerError(
          category: "network",
          code: "network.range_not_supported",
          message: "The server ignored a nonzero byte-range request.",
          diagnostic: Self.sanitized(response.url)
        )
      }
      let metadata = metadata(
        response: response,
        start: 0,
        length: try parseContentLength(response),
        randomAccess: false,
        isEOF: false
      )
      try validateRepresentation(metadata)
      return metadata

    case 416:
      let length = try parseUnsatisfiedLength(
        response.value(forHTTPHeaderField: "Content-Range")
      )
      let knownLength = snapshotValidator()?.resourceLength
      guard knownLength == requestedOffset, length == requestedOffset else {
        throw rangeInvalid("Range was not satisfiable at the known resource end")
      }
      return metadata(
        response: response,
        start: requestedOffset,
        length: length,
        randomAccess: true,
        isEOF: true
      )

    default:
      throw NativePlayerError(
        category: "network",
        code: "network.http_status",
        message: "The server returned an unsupported HTTP status.",
        diagnostic: "HTTP \(status) \(Self.sanitized(response.url))"
      )
    }
  }

  static func isRetryableStatus(_ statusCode: Int) -> Bool {
    statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
  }

  private func makeRequest(
    url: URL,
    headers: [String: String],
    offset: Int64,
    validator: YlNetworkResponseMetadata?
  ) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = TimeInterval(recipe.configuration.connectTimeoutMs) / 1_000
    for (name, value) in headers where !Self.ownedHeaderNames.contains(name.lowercased()) {
      request.setValue(value, forHTTPHeaderField: name)
    }
    if recipe.mode == .randomAccessVOD {
      request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
      if let validator = Self.ifRangeValue(validator) {
        request.setValue(validator, forHTTPHeaderField: "If-Range")
      }
    }
    return request
  }

  private func metadata(
    response: HTTPURLResponse,
    start: Int64,
    length: Int64?,
    randomAccess: Bool,
    isEOF: Bool
  ) -> YlNetworkResponseMetadata {
    YlNetworkResponseMetadata(
      responseStart: start,
      resourceLength: length,
      supportsRandomAccess: randomAccess,
      etag: Self.trimmedHeader(response.value(forHTTPHeaderField: "ETag")),
      lastModified: Self.trimmedHeader(
        response.value(forHTTPHeaderField: "Last-Modified")
      ),
      isEOF: isEOF
    )
  }

  private func validateRepresentation(_ received: YlNetworkResponseMetadata) throws {
    guard let expected = snapshotValidator() else { return }
    if let expectedLength = expected.resourceLength,
       let receivedLength = received.resourceLength,
       expectedLength != receivedLength {
      throw contentChanged(nil)
    }
    if let expectedETag = Self.strongETag(expected.etag),
       let receivedETag = Self.strongETag(received.etag),
       expectedETag != receivedETag {
      throw contentChanged(nil)
    }
    if Self.strongETag(expected.etag) == nil,
       let expectedDate = expected.lastModified,
       let receivedDate = received.lastModified,
       expectedDate != receivedDate {
      throw contentChanged(nil)
    }
  }

  private func snapshotValidator() -> YlNetworkResponseMetadata? {
    lock.lock()
    defer { lock.unlock() }
    return currentValidator
  }

  private func parseContentLength(_ response: HTTPURLResponse) throws -> Int64? {
    guard let raw = Self.trimmedHeader(
      response.value(forHTTPHeaderField: "Content-Length")
    ) else { return nil }
    guard let value = Self.nonnegativeInt64(raw) else {
      throw rangeInvalid("Invalid Content-Length")
    }
    return value
  }

  private func parsePartialContentRange(
    _ rawValue: String?
  ) throws -> (start: Int64, end: Int64, total: Int64?, length: Int64) {
    guard let raw = Self.trimmedHeader(rawValue),
          raw.lowercased().hasPrefix("bytes ") else {
      throw rangeInvalid("Missing Content-Range")
    }
    let value = raw.dropFirst(6)
    let halves = value.split(separator: "/", omittingEmptySubsequences: false)
    guard halves.count == 2 else { throw rangeInvalid("Invalid Content-Range") }
    let bounds = halves[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2,
          let start = Self.nonnegativeInt64(String(bounds[0])),
          let end = Self.nonnegativeInt64(String(bounds[1])),
          end >= start else {
      throw rangeInvalid("Invalid Content-Range bounds")
    }
    let distance = end.subtractingReportingOverflow(start)
    let length = distance.partialValue.addingReportingOverflow(1)
    guard !distance.overflow, !length.overflow else {
      throw rangeInvalid("Content-Range overflow")
    }
    let total: Int64?
    if halves[1] == "*" {
      total = nil
    } else {
      guard let parsed = Self.nonnegativeInt64(String(halves[1])), parsed > end else {
        throw rangeInvalid("Invalid Content-Range total")
      }
      total = parsed
    }
    return (start, end, total, length.partialValue)
  }

  private func parseUnsatisfiedLength(_ rawValue: String?) throws -> Int64 {
    guard let raw = Self.trimmedHeader(rawValue) else {
      throw rangeInvalid("Missing Content-Range")
    }
    let parts = raw.split(separator: " ", maxSplits: 1)
    guard parts.count == 2,
          parts[0].lowercased() == "bytes",
          parts[1].hasPrefix("*/"),
          let length = Self.nonnegativeInt64(String(parts[1].dropFirst(2))) else {
      throw rangeInvalid("Invalid unsatisfied Content-Range")
    }
    return length
  }

  private func rangeInvalid(_ detail: String) -> NativePlayerError {
    NativePlayerError(
      category: "network",
      code: "network.range_invalid",
      message: "The server returned an invalid byte range.",
      diagnostic: detail
    )
  }

  private func rangeNotSupported() -> NativePlayerError {
    NativePlayerError(
      category: "network",
      code: "network.range_not_supported",
      message: "This network source does not support random access."
    )
  }

  private func contentChanged(_ url: URL?) -> NativePlayerError {
    NativePlayerError(
      category: "network",
      code: "network.content_changed",
      message: "The network media changed while it was open.",
      diagnostic: url.map(Self.sanitized)
    )
  }

  private static func validateHTTPURL(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https",
          url.host != nil else {
      throw NativePlayerError(
        category: "network",
        code: "network.invalid_redirect",
        message: "Only HTTP and HTTPS network destinations are supported.",
        diagnostic: sanitized(url)
      )
    }
  }

  private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    guard let leftScheme = lhs.scheme?.lowercased(),
          let rightScheme = rhs.scheme?.lowercased(),
          let leftHost = lhs.host?.lowercased(),
          let rightHost = rhs.host?.lowercased() else { return false }
    return leftScheme == rightScheme &&
      leftHost == rightHost &&
      effectivePort(lhs, scheme: leftScheme) == effectivePort(rhs, scheme: rightScheme)
  }

  private static func effectivePort(_ url: URL, scheme: String) -> Int? {
    url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
  }

  private static func ifRangeValue(_ metadata: YlNetworkResponseMetadata?) -> String? {
    guard let metadata else { return nil }
    if let etag = strongETag(metadata.etag) { return etag }
    guard metadata.resourceLength != nil else { return nil }
    return metadata.lastModified
  }

  private static func strongETag(_ value: String?) -> String? {
    guard let value = trimmedHeader(value),
          !value.lowercased().hasPrefix("w/") else { return nil }
    return value
  }

  private static func trimmedHeader(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  private static func nonnegativeInt64(_ value: String) -> Int64? {
    guard !value.isEmpty,
          value.allSatisfy({ $0.isASCII && $0.isNumber }),
          let parsed = Int64(value),
          parsed >= 0 else { return nil }
    return parsed
  }

  private static func sanitized(_ url: URL?) -> String {
    guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return "invalid-url" }
    components.user = nil
    components.password = nil
    components.query = nil
    components.fragment = nil
    return components.url?.absoluteString ?? "invalid-url"
  }

  private static let ownedHeaderNames: Set<String> = ["range", "if-range"]
  private static let credentialHeaderNames: Set<String> = [
    "authorization", "cookie", "proxy-authorization",
  ]
}
