import Foundation
import yl_player_media_core

/// Main-thread owner of one preparation and one accepted media resource.
/// The compressed producer runs independently of any playback or audio output.
final class YlMediaDeliveryManager: YlMediaDeliverySession {
  typealias Preparation = (YlMediaDeliveryInput, YlOpenCancellationToken) throws -> YlDeliveredMedia
  private final class Pending {
    let id: String
    let input: YlMediaDeliveryInput
    let token = YlOpenCancellationToken()
    var reply: ((Result<URL, Error>) -> Void)?
    init(id: String, input: YlMediaDeliveryInput, reply: @escaping (Result<URL, Error>) -> Void) { self.id = id; self.input = input; self.reply = reply }
    func finish(_ result: Result<URL, Error>) { let callback = reply; reply = nil; callback?(result) }
  }
  private let producer: Preparation
  private let currentAddress: () throws -> String
  private let queue = DispatchQueue(label: "dev.yl.delivery.prepare", qos: .userInitiated)
  private var pending: Pending?
  private var accepted: (id: String, media: YlDeliveredMedia)?
  private var monitor: DispatchSourceTimer?
  private var closed = false
  private var running = false
  var onState: ((String, String, NativePlayerError?) -> Void)?

  init(prepare: @escaping Preparation = { try YlAirPlayLiveRemux.prepare(input: $0, token: $1) },
       currentAddress: @escaping () throws -> String = YlAirPlayHTTPServer.lanIPv4Address) {
    producer = prepare; self.currentAddress = currentAddress
  }

  func prepare(id: String, input: YlMediaDeliveryInput,
               reply: @escaping (Result<URL, Error>) -> Void) {
    do { try validate(input: input) }
    catch { reply(.failure(error)); return }
    cancelPending()
    pending = Pending(id: id, input: input, reply: reply)
    startPending()
  }

  func validate(input: YlMediaDeliveryInput) throws {
    guard !closed else { throw NativePlayerError(category: "lifecycle", code: "player.disposed", message: "Delivery is disposed.") }
    guard input.isLive else { throw YlAirPlayRemux.failure("unsupported_source", "Delivery requires live media.") }
    switch input.recipe {
    case .rtmp: break
    case .network(let request, let container):
      guard container == .flv, request.managedIntent == nil else {
        throw NativePlayerError(category: "unsupported", code: "policy.unsupported", message: "The delivery policy is unsupported.")
      }
    default: throw YlAirPlayRemux.failure("unsupported_source", "Delivery requires HTTP-FLV or RTMP.")
    }
  }

  private func startPending() {
    guard !closed, !running, let operation = pending else { return }
    running = true
    queue.async { [weak self, producer] in
      let result = Result { () throws -> YlDeliveredMedia in
        try operation.token.throwIfCancelled()
        return try producer(operation.input, operation.token)
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
          operation.finish(.success(media.url))
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
    onState?(owned.id, "closed", nil)
  }

  private func fail(id: String, error: Error) {
    guard accepted?.id == id else { return }
    monitor?.cancel(); monitor = nil
    accepted = nil // Retires the producer and server before reporting failure.
    onState?(id, "failed", error as? NativePlayerError ?? YlAirPlayRemux.failure("remux_failed", "Delivery failed."))
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
