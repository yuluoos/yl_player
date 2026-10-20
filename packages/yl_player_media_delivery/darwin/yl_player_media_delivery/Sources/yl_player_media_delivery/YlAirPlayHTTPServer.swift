import yl_player_media_core
import Darwin
import Foundation
import Network

/// Ownership of the open descriptor transfers to the HTTP connection.
final class YlAirPlayHTTPResource {
  let file: FileHandle
  let length: Int
  let contentType: String
  private let lock = NSLock()
  private var onClose: (() -> Void)?
  private var closed = false

  init(file: FileHandle, length: Int, contentType: String, onClose: (() -> Void)? = nil) {
    self.file = file; self.length = length; self.contentType = contentType; self.onClose = onClose
  }

  func close() throws {
    lock.lock()
    guard !closed else { lock.unlock(); return }
    closed = true
    let release = onClose
    onClose = nil
    lock.unlock()
    // Release accounting only after the descriptor has been closed.
    defer { release?() }
    try file.close()
  }

  deinit { try? close() }
}

/// A private HTTP media origin. Only explicitly published basenames
/// under a fresh 128-bit capability are accessible; no source credentials leave it.
final class YlAirPlayHTTPServer {
  let url: URL
  private let listener: NWListener
  private let queue = DispatchQueue(label: "dev.ylplayer.airplay.http")
  private var connections: [UUID: YlAirPlayHTTPConnection] = [:]
  private var stopped = false
  private let queueKey = DispatchSpecificKey<Bool>()

  convenience init(directory: URL, files: Set<String>, host: String) throws {
    try self.init(host: host) { name in
      guard files.contains(name) else { return nil }
      let file = try FileHandle(forReadingFrom: directory.appendingPathComponent(name))
      do {
        let size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        return YlAirPlayHTTPResource(file: file, length: Int(size),
          contentType: name.hasSuffix("m3u8") ? "application/vnd.apple.mpegurl" : "video/mp4")
      } catch { try? file.close(); throw error }
    }
  }

  init(host: String, resolver: @escaping (String) throws -> YlAirPlayHTTPResource?) throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: .any)
    listener = try NWListener(using: parameters)
    queue.setSpecific(key: queueKey, value: true)
    let ready = DispatchSemaphore(value: 0)
    let state = YlAirPlayListenerState()
    listener.stateUpdateHandler = { value in
      switch value {
      case .ready: state.ready = true; ready.signal()
      case .failed(let error): state.error = String(describing: error); ready.signal()
      default: break
      }
    }
    listener.newConnectionHandler = { $0.cancel() }
    listener.start(queue: queue)
    guard ready.wait(timeout: .now() + 5) == .success, state.ready, let port = listener.port else {
      listener.cancel()
      throw YlAirPlayRemux.failure("lan_unavailable", "The local AirPlay HTTP listener could not start.", diagnostic: state.error)
    }
    let capability = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    url = URL(string: "http://\(host):\(port.rawValue)/\(capability)/index.m3u8")!
    listener.newConnectionHandler = { [weak self] connection in
      guard let self, !self.stopped, self.connections.count < 8 else { connection.cancel(); return }
      let id = UUID()
      let client = YlAirPlayHTTPConnection(connection: connection, queue: self.queue,
        resolver: resolver, capability: capability,
        onFinish: { [weak self] in self?.connections.removeValue(forKey: id) })
      self.connections[id] = client
      client.start()
    }
  }

  func stop() {
    listener.cancel()
    let close = {
      self.stopped = true
      let clients = Array(self.connections.values)
      self.connections.removeAll()
      clients.forEach { $0.finish() }
    }
    if DispatchQueue.getSpecific(key: queueKey) == true { close() }
    else { queue.sync(execute: close) }
  }

  deinit { stop() }

  /// Advertise only a running physical Wi-Fi/Ethernet IPv4 interface. Loopback,
  /// VPN, link-local and virtual bridge addresses cannot be assumed receiver-reachable.
  static func lanIPv4Address() throws -> String {
    var interfaces: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&interfaces) == 0 else { throw YlAirPlayRemux.failure("lan_unavailable", "No LAN interface is available for AirPlay.") }
    defer { freeifaddrs(interfaces) }
    var candidates: [(String, String)] = []
    var cursor = interfaces
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      let entry = current.pointee
      let name = String(cString: entry.ifa_name)
      guard name.hasPrefix("en"), let address = entry.ifa_addr,
            address.pointee.sa_family == UInt8(AF_INET),
            entry.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
            entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
      let host = String(cString: buffer)
      guard !host.hasPrefix("169.254."), !host.hasPrefix("127."), host != "0.0.0.0" else { continue }
      candidates.append((name, host))
    }
    guard let host = candidates.sorted(by: { $0.0 < $1.0 }).first?.1 else {
      throw YlAirPlayRemux.failure("lan_unavailable", "AirPlay remux requires a Wi-Fi or Ethernet IPv4 address reachable by the receiver.")
    }
    return host
  }
}

private final class YlAirPlayListenerState { var ready = false; var error: String? }

private final class YlAirPlayHTTPConnection {
  let connection: NWConnection
  private let queue: DispatchQueue
  private let resolver: (String) throws -> YlAirPlayHTTPResource?
  private let capability: String
  private let onFinish: () -> Void
  private var input = Data()
  private var resource: YlAirPlayHTTPResource?
  private var remaining = 0
  private var completed = false
  private var timeout: DispatchWorkItem?

  init(connection: NWConnection, queue: DispatchQueue, resolver: @escaping (String) throws -> YlAirPlayHTTPResource?,
       capability: String, onFinish: @escaping () -> Void) {
    self.connection = connection; self.queue = queue; self.resolver = resolver
    self.capability = capability; self.onFinish = onFinish
  }

  func start() {
    connection.stateUpdateHandler = { [weak self] state in
      if case .failed = state { self?.finish() }
      if case .cancelled = state { self?.finish() }
    }
    connection.start(queue: queue)
    let timeout = DispatchWorkItem { [weak self] in self?.finish() }
    self.timeout = timeout
    queue.asyncAfter(deadline: .now() + 30, execute: timeout)
    receive()
  }

  func finish() {
    guard !completed else { return }
    completed = true
    timeout?.cancel()
    timeout = nil
    try? resource?.close()
    resource = nil
    connection.cancel()
    onFinish()
  }

  private func receive() {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - input.count) { [weak self] data, _, ended, error in
      guard let self, !self.completed else { return }
      if let data { self.input.append(data) }
      if let delimiter = self.input.range(of: Data("\r\n\r\n".utf8)) {
        self.respond(header: self.input[..<delimiter.lowerBound])
      } else if error != nil || ended { self.finish() }
      else if self.input.count >= 8192 { self.sendError(431, "Request Header Fields Too Large") }
      else { self.receive() }
    }
  }

  private func respond(header: Data) {
    guard let text = String(data: header, encoding: .utf8) else { sendError(400, "Bad Request"); return }
    let lines = text.components(separatedBy: "\r\n")
    let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
    guard request.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(String(request[2])) else { sendError(400, "Bad Request"); return }
    let method = String(request[0])
    guard method == "GET" || method == "HEAD" else { sendError(405, "Method Not Allowed"); return }
    let path = String(request[1])
    let prefix = "/\(capability)/"
    guard path.hasPrefix(prefix) else { sendError(404, "Not Found"); return }
    let name = String(path.dropFirst(prefix.count))
    guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("%"), !name.contains("\\") else { sendError(404, "Not Found"); return }
    var range: String?
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { sendError(400, "Bad Request"); return }
      let key = line[..<colon].lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      if key == "range" {
        guard range == nil else { sendError(416, "Range Not Satisfiable"); return }
        range = value
      }
      if key == "transfer-encoding" || (key == "content-length" && value != "0") { sendError(400, "Bad Request"); return }
    }
    do {
      guard let resource = try resolver(name) else { sendError(404, "Not Found"); return }
      self.resource = resource
      let size = resource.length
      guard size > 0 else { sendError(404, "Not Found"); return }
      let bounds: ClosedRange<Int>
      if let range {
        guard let parsed = Self.parseRange(range, size: size) else {
          sendError(416, "Range Not Satisfiable", extra: "Content-Range: bytes */\(size)\r\n"); return
        }
        bounds = parsed
      } else { bounds = 0...(size - 1) }
      let type = resource.contentType
      let cache = name.hasSuffix("m3u8") ? "no-store" : "private, max-age=3600"
      let status = range == nil ? "200 OK" : "206 Partial Content"
      let rangeHeader = range == nil ? "" : "Content-Range: bytes \(bounds.lowerBound)-\(bounds.upperBound)/\(size)\r\n"
      remaining = bounds.count
      let response = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(remaining)\r\nAccept-Ranges: bytes\r\n\(rangeHeader)Cache-Control: \(cache)\r\nConnection: close\r\n\r\n"
      if method == "GET" {
        try resource.file.seek(toOffset: UInt64(bounds.lowerBound))
      }
      connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        if error != nil || method == "HEAD" { self.finish() } else { self.sendChunk() }
      })
    } catch { sendError(404, "Not Found") }
  }

  private func sendChunk() {
    guard !completed, remaining > 0, let file = resource?.file else { finish(); return }
    do {
      guard let data = try file.read(upToCount: min(64 * 1024, remaining)), !data.isEmpty else { finish(); return }
      remaining -= data.count
      connection.send(content: data, completion: .contentProcessed { [weak self] error in
        if error != nil { self?.finish() } else { self?.sendChunk() }
      })
    } catch { finish() }
  }

  private func sendError(_ code: Int, _ reason: String, extra: String = "") {
    connection.send(content: Data("HTTP/1.1 \(code) \(reason)\r\n\(extra)Content-Length: 0\r\nConnection: close\r\n\r\n".utf8),
      completion: .contentProcessed { [weak self] _ in self?.finish() })
  }

  private static func parseRange(_ value: String, size: Int) -> ClosedRange<Int>? {
    guard value.hasPrefix("bytes=") else { return nil }
    let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    if parts[0].isEmpty {
      guard let suffix = Int(parts[1]), suffix > 0 else { return nil }
      return max(0, size - suffix)...(size - 1)
    }
    guard let start = Int(parts[0]), start >= 0, start < size else { return nil }
    let end: Int
    if parts[1].isEmpty { end = size - 1 }
    else { guard let parsed = Int(parts[1]), parsed >= start else { return nil }; end = min(parsed, size - 1) }
    return start...end
  }
}
