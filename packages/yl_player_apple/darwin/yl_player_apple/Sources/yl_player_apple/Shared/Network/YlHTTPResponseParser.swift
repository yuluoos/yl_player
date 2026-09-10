import Foundation

/// Bounded HTTP/1 response framing. Header/trailer bytes are metadata; emitted
/// body slices belong to the caller until consumed (Task 4's payload ledger).
final class YlHTTPResponseParser {
  enum Event { case headers(HTTPURLResponse), body(Data), complete }
  private enum State { case headers, fixed(Int64), close, chunkSize, chunk(Int64), chunkEnd, trailers, done }
  static let maximumHeaderBytes = 64 * 1024
  private let url: URL
  private let method: String
  private var state = State.headers
  private var buffer = Data()
  private var headerBytes = 0

  init(url: URL, method: String = "GET") { self.url = url; self.method = method }

  func receive(_ data: Data) throws -> [Event] {
    buffer.append(data)
    var events = [Event]()
    while true {
      switch state {
      case .headers:
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
          try requireHeaderBudget(buffer.count); return events
        }
        let count = buffer.distance(from: buffer.startIndex, to: end.upperBound)
        try requireHeaderBudget(count)
        headerBytes += count
        let raw = buffer.prefix(count)
        buffer.removeFirst(count)
        let response = try parseHeaders(Data(raw))
        if (100..<200).contains(response.statusCode) {
          guard response.statusCode != 101,
                response.value(forHTTPHeaderField: "Content-Length") == nil,
                response.value(forHTTPHeaderField: "Transfer-Encoding") == nil else { throw Self.invalid("network.protocol_unsupported") }
          continue
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity" else { throw Self.invalid("network.encoding_unsupported") }
        let transfer = response.value(forHTTPHeaderField: "Transfer-Encoding")?.lowercased()
        let length = response.value(forHTTPHeaderField: "Content-Length")
        guard transfer == nil || (transfer == "chunked" && length == nil) else { throw Self.invalid() }
        if method == "HEAD" || response.statusCode == 204 || response.statusCode == 304 {
          state = .done
        } else if transfer != nil { state = .chunkSize }
        else if let length {
          guard !length.isEmpty, length.allSatisfy({ $0.isASCII && $0.isNumber }),
                let count = Int64(length) else { throw Self.invalid() }
          state = count == 0 ? .done : .fixed(count)
        } else { state = .close }
        events.append(.headers(response))
      case let .fixed(remaining):
        guard !buffer.isEmpty else { return events }
        let count = Int(min(remaining, Int64(buffer.count)))
        events.append(.body(Data(buffer.prefix(count))))
        buffer.removeFirst(count)
        state = remaining == Int64(count) ? .done : .fixed(remaining - Int64(count))
      case .close:
        if !buffer.isEmpty { events.append(.body(buffer)); buffer = Data() }
        return events
      case .chunkSize:
        guard let end = buffer.range(of: Data("\r\n".utf8)) else {
          guard buffer.count <= Self.maximumHeaderBytes else { throw Self.invalid() }; return events
        }
        guard buffer.distance(from: buffer.startIndex, to: end.upperBound) <= Self.maximumHeaderBytes else { throw Self.invalid() }
        let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        guard line.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && $0.value <= 255 }) else { throw Self.invalid() }
        let size = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard !size.isEmpty, size.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let count = Int64(size, radix: 16) else { throw Self.invalid() }
        buffer.removeSubrange(..<end.upperBound)
        state = count == 0 ? .trailers : .chunk(count)
      case let .chunk(remaining):
        guard !buffer.isEmpty else { return events }
        let count = Int(min(remaining, Int64(buffer.count)))
        events.append(.body(Data(buffer.prefix(count))))
        buffer.removeFirst(count)
        state = remaining == Int64(count) ? .chunkEnd : .chunk(remaining - Int64(count))
      case .chunkEnd:
        guard buffer.count >= 2 else { return events }
        guard buffer.prefix(2) == Data("\r\n".utf8) else { throw Self.invalid() }
        buffer.removeFirst(2); state = .chunkSize
      case .trailers:
        guard let end = buffer.range(of: Data("\r\n".utf8)) else {
          try requireHeaderBudget(buffer.count); return events
        }
        let count = buffer.distance(from: buffer.startIndex, to: end.upperBound)
        try requireHeaderBudget(count); headerBytes += count
        if count == 2 { buffer.removeFirst(2); state = .done }
        else {
          let line = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
          let (name, _) = try Self.header(line)
          guard !["content-length", "transfer-encoding", "host"].contains(name.lowercased()) else { throw Self.invalid() }
          buffer.removeFirst(count)
        }
      case .done:
        guard buffer.isEmpty else { throw Self.invalid() }
        events.append(.complete); return events
      }
    }
  }

  func endOfStream() throws -> [Event] {
    switch state {
    case .close: state = .done; return [.complete]
    case .done: return []
    default: throw URLError(.networkConnectionLost)
    }
  }

  private func requireHeaderBudget(_ count: Int) throws {
    guard count <= Self.maximumHeaderBytes - headerBytes else { throw Self.invalid("network.headers_too_large") }
  }

  private func parseHeaders(_ data: Data) throws -> HTTPURLResponse {
    guard let text = String(data: data, encoding: .isoLatin1) else { throw Self.invalid() }
    let lines = text.components(separatedBy: "\r\n")
    let status = lines[0].split(separator: " ", maxSplits: 2)
    guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(status[0]),
          status[1].count == 3, let code = Int(status[1]), (100...599).contains(code) else { throw Self.invalid() }
    var headers = [String: String]()
    for line in lines.dropFirst() where !line.isEmpty {
      let (name, value) = try Self.header(line)
      let key = name.lowercased()
      if let previous = headers[key] {
        guard !["content-length", "transfer-encoding"].contains(key) else { throw Self.invalid() }
        headers[key] = previous + ", " + value
      } else { headers[key] = value }
    }
    guard let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: String(status[0]), headerFields: headers) else {
      throw Self.invalid()
    }
    return response
  }

  static func header(_ line: String) throws -> (String, String) {
    guard let colon = line.firstIndex(of: ":") else { throw invalid() }
    let name = String(line[..<colon])
    let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    try validateHeader(name: name, value: value)
    return (name, value)
  }

  static func validateHeader(name: String, value: String) throws {
    let punctuation = Set("!#$%&'*+-.^_`|~")
    guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || punctuation.contains($0)) }),
          value.unicodeScalars.allSatisfy({ $0.value == 9 || ($0.value >= 32 && $0.value != 127 && $0.value <= 255) }) else {
      throw invalid()
    }
  }

  static func invalid(_ code: String = "network.response_invalid") -> NativePlayerError {
    NativePlayerError(category: "network", code: code, message: "The managed HTTP response is unsupported or invalid.", diagnostic: "network.framing")
  }
}
