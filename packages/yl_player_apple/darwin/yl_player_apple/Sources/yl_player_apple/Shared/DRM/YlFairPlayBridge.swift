import yl_player_media_core
import Foundation
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

final class YlFairPlayBridge: AppleDrmHostApi {
  let playerId: Int64
  let views: YlFairPlayViewRegistry
  private let callbacks: AppleDrmFlutterApiProtocol
  private var pending: [String: Task<Void, Never>] = [:]
  var cancelLoad: ((String) -> Void)?
  init(playerId: Int64, views: YlFairPlayViewRegistry, callbacks: AppleDrmFlutterApiProtocol) {
    self.playerId = playerId; self.views = views; self.callbacks = callbacks
  }
  func exchange(surface: YlFairPlaySurfaceIdentity, loadId: String,
                id: YlFairPlayExchangeIdentity, challenge: Data,
                completion: @escaping (Result<Data, NativePlayerError>) -> Void) -> () -> Void {
    guard surface.playerId == playerId, pending.count < 4 else {
      completion(.failure(YlFairPlayFailure.error("resource.exhausted"))); return {}
    }
    let identity = AppleDrmExchangeId(surface: surface.message, loadRequestId: loadId,
      epoch: id.epoch, requestId: id.requestId, exchangeId: UUID().uuidString)
    let callbacks = self.callbacks
    let task = Task { @MainActor [weak self] in
      let result: Result<Data, NativePlayerError>
      do {
        let reply = try await callbacks.exchangeLicense(request: .init(id: identity,
          challenge: FlutterStandardTypedData(bytes: challenge)))
        guard !Task.isCancelled, self?.pending[identity.exchangeId] != nil else { return }
        guard reply.id == identity else { throw YlFairPlayFailure.error("drm.license_response_invalid") }
        if let code = reply.failureCode {
          throw YlFairPlayFailure.transport(YlFairPlayFailure.error(code))
        }
        guard let data = reply.response?.data, !data.isEmpty else {
          throw YlFairPlayFailure.error("drm.license_response_invalid")
        }
        guard data.count <= 4 * 1024 * 1024 else { throw YlFairPlayFailure.error("drm.payload_too_large") }
        result = .success(data)
      } catch let error as NativePlayerError { result = .failure(YlFairPlayFailure.transport(error)) }
      catch { result = .failure(YlFairPlayFailure.error("drm.license_failed")) }
      guard !Task.isCancelled, self?.pending.removeValue(forKey: identity.exchangeId) != nil else { return }
      completion(result)
    }
    pending[identity.exchangeId] = task
    return { [weak self] in
      self?.pending.removeValue(forKey: identity.exchangeId)?.cancel()
      Task { try? await callbacks.cancelLicense(id: identity) }
    }
  }
  func frame(_ frame: AppleProtectedViewAck) {
    let callbacks = callbacks
    Task { try? await callbacks.onProtectedFrame(frame: frame) }
  }
  func cancelProtectedLoad(loadRequestId: String) throws { cancelLoad?(loadRequestId) }
  func attachProtectedView(command: AppleProtectedViewCommand) async throws -> AppleProtectedViewAck {
    try await MainActor.run {
      guard command.surface.playerId == self.playerId,
            let record = self.views.lookup(.init(command.surface)) else {
        throw YlAppleFailureMapper.command(YlFairPlayFailure.error("drm.protection_insufficient"))
      }
      do { return try record.ack(viewId: command.viewId) }
      catch { throw YlAppleFailureMapper.command(error) }
    }
  }
  func detachProtectedView(command: AppleProtectedViewCommand) async throws -> AppleProtectedViewAck {
    await MainActor.run {
      guard command.surface.playerId == self.playerId,
            let record = self.views.lookup(.init(command.surface)) else {
        return .init(surface: command.surface, viewId: command.viewId, revision: 0, attached: false)
      }
      return record.detach(viewId: command.viewId)
    }
  }
}
