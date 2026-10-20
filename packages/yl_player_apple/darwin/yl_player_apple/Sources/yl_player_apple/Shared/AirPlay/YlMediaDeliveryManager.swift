import Foundation

/// Main-thread owner of one preparation and one accepted media resource.
/// The compressed producer runs independently of any playback or audio output.
final class YlMediaDeliveryManager {
  typealias Preparation = (YlAppleSourceDescriptor, PlayerConfiguration, YlOpenCancellationToken) throws -> YlAirPlayPreparedMedia
  private final class Pending {
    let id: String
    let source: YlAppleSourceDescriptor
    let token = YlOpenCancellationToken()
    var reply: ((Result<[String: Any], Error>) -> Void)?
    init(id: String, source: YlAppleSourceDescriptor, reply: @escaping (Result<[String: Any], Error>) -> Void) { self.id = id; self.source = source; self.reply = reply }
    func finish(_ result: Result<[String: Any], Error>) { let callback = reply; reply = nil; callback?(result) }
  }
  private let configuration: PlayerConfiguration
  private let producer: Preparation
  private let currentAddress: () throws -> String
  private let queue = DispatchQueue(label: "dev.yl.delivery.prepare", qos: .userInitiated)
  private var pending: Pending?
  private var accepted: (id: String, media: YlAirPlayPreparedMedia)?
  private var monitor: DispatchSourceTimer?
  private var closed = false
  private var running = false
  var onState: (([String: Any]) -> Void)?

  init(configuration: PlayerConfiguration,
       prepare: @escaping Preparation = { try YlAirPlayLiveRemux.prepare(source: $0, configuration: $1, token: $2) },
       currentAddress: @escaping () throws -> String = YlAirPlayHTTPServer.lanIPv4Address) {
    self.configuration = configuration; producer = prepare; self.currentAddress = currentAddress
  }

  func prepare(id: String, source: YlAppleSourceDescriptor,
               reply: @escaping (Result<[String: Any], Error>) -> Void) {
    do { try validateAdmission(source: source) }
    catch { reply(.failure(error)); return }
    cancelPending()
    pending = Pending(id: id, source: source, reply: reply)
    startPending()
  }

  /// Side-effect-free admission shared by transport preflight and production.
  func validateAdmission(source: YlAppleSourceDescriptor) throws {
    guard !closed else { throw YlAppleFailureMapper.invalid("player.disposed") }
    try Self.validateSource(source)
  }

  private static func validateSource(_ source: YlAppleSourceDescriptor) throws {
    // The shared live worker bounds timeouts and owns a fixed recovery budget;
    // it cannot claim enforcement of the caller's managed-network policy.
    guard source.networkPolicy == .platformDefault else { throw YlAppleFailureMapper.unsupported }
    guard source.kind == .network, source.drm == nil, source.intent != .onDemand,
          let url = source.url, let scheme = url.scheme?.lowercased(),
          source.formatHint == .automatic || source.formatHint == .flv else {
      throw YlAirPlayRemux.failure("unsupported_source", "Media delivery requires an unprotected live FLV or RTMP source.")
    }
    switch scheme {
    case "rtmp", "rtmps": return
    case "http", "https":
      guard source.formatHint == .flv ||
              (source.formatHint == .automatic && url.pathExtension.lowercased() == "flv") else {
        throw YlAirPlayRemux.failure("unsupported_source", "HTTP media delivery requires an FLV source.")
      }
    default:
      throw YlAirPlayRemux.failure("unsupported_source", "Media delivery supports HTTP-FLV, RTMP and RTMPS only.")
    }
  }

  private func startPending() {
    guard !closed, !running, let operation = pending else { return }
    running = true
    queue.async { [weak self, producer, configuration] in
      let result = Result { () throws -> YlAirPlayPreparedMedia in
        try operation.token.throwIfCancelled()
        return try producer(operation.source, configuration, operation.token)
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.running = false
        guard !self.closed, self.pending === operation, !operation.token.isCancelled else { self.startPending(); return }
        self.pending = nil
        switch result {
        case .failure(let error): operation.finish(.failure(error))
        case .success(let media):
          self.releaseAccepted()
          self.accepted = (operation.id, media)
          media.observeFailure { [weak self] error in
            DispatchQueue.main.async { self?.fail(id: operation.id, error: error) }
          }
          self.startMonitor(id: operation.id, host: media.url.host)
          operation.finish(.success(["id": operation.id, "uri": media.url.absoluteString,
            "contentType": "application/vnd.apple.mpegurl", "isLive": true]))
        }
      }
    }
  }

  func release(id: String) {
    if pending?.id == id { cancelPending() }
    if accepted?.id == id { releaseAccepted() }
  }

  func close() {
    guard !closed else { return }
    closed = true
    cancelPending(); releaseAccepted(); onState = nil
  }

  private func cancelPending() {
    guard let operation = pending else { return }
    pending = nil
    operation.token.cancel()
    operation.finish(.failure(NativePlayerError(category: "cancelled", code: "load.cancelled", message: "Media delivery preparation was cancelled.")))
  }

  private func releaseAccepted() {
    monitor?.cancel(); monitor = nil
    guard let owned = accepted else { return }
    accepted = nil
    onState?(["id": owned.id, "status": "closed"])
  }

  private func fail(id: String, error: Error) {
    guard accepted?.id == id else { return }
    monitor?.cancel(); monitor = nil
    accepted = nil // Retires the producer and server before reporting failure.
    onState?(["id": id, "status": "failed", "failure": YlAppleFailureMapper.message(error, scope: .command)])
  }

  private func startMonitor(id: String, host: String?) {
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 1, repeating: 1)
    timer.setEventHandler { [weak self] in
      guard let self else { return }
      if (try? self.currentAddress()) != host {
        self.fail(id: id, error: YlAirPlayRemux.failure("lan_unavailable", "The media delivery network interface changed."))
      }
    }
    monitor = timer; timer.resume()
  }
  deinit { pending?.token.cancel(); monitor?.cancel() }
}
