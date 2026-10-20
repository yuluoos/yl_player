import Foundation
import yl_player_media_core

/// Legacy player-scoped API delegates to the optional delivery module.
final class YlMediaDeliveryManager {
  private let configuration: PlayerConfiguration
  private let service: () throws -> any YlMediaDeliveryService
  private var session: (any YlMediaDeliverySession)?
  private var closed = false
  var onState: (([String: Any]) -> Void)?
  init(configuration: PlayerConfiguration,
       service: @escaping () throws -> any YlMediaDeliveryService = { throw YlMediaDeliveryRegistry.unavailable() }) {
    self.configuration = configuration; self.service = service
  }
  private func active() throws -> any YlMediaDeliverySession {
    guard !closed else { throw YlAppleFailureMapper.invalid("player.disposed") }
    if let session { return session }
    let created = try service().makeSession()
    created.onState = { [weak self] id, status, error in
      var event: [String: Any] = ["id": id, "status": status]
      if let error { event["failure"] = YlAppleFailureMapper.message(error, scope: .command) }
      self?.onState?(event)
    }
    session = created
    return created
  }
  private func input(_ source: YlAppleSourceDescriptor) throws -> YlMediaDeliveryInput {
    guard source.networkPolicy == .platformDefault else { throw YlAppleFailureMapper.unsupported }
    guard source.formatHint == .automatic || source.formatHint == .flv else {
      throw YlAirPlayRemux.failure("unsupported_source", "Live delivery requires FLV or RTMP.")
    }
    return try YlAppleDeliveryInput.make(source: source, configuration: configuration, live: true)
  }
  func validateAdmission(source: YlAppleSourceDescriptor) throws {
    let projected = try input(source)
    try active().validate(input: projected)
  }
  func prepare(id: String, source: YlAppleSourceDescriptor,
               reply: @escaping (Result<[String: Any], Error>) -> Void) {
    do {
      let projected = try input(source)
      try active().prepare(id: id, input: projected) { result in
        reply(result.map { ["id": id, "uri": $0.absoluteString,
          "contentType": "application/vnd.apple.mpegurl", "isLive": true] })
      }
    } catch { reply(.failure(error)) }
  }
  func release(id: String) { session?.release(id: id) }
  func close() {
    guard !closed else { return }
    closed = true; session?.close(); session = nil; onState = nil
  }
}
