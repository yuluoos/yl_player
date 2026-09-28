import AVFoundation
import Foundation

struct YlFairPlaySurfaceIdentity: Equatable {
  let playerId: Int64
  let surfaceId: Int64
  let sessionId: String
  let generation: Int64
  var message: AppleProtectedSurfaceMessage {
    .init(playerId: playerId, surfaceId: surfaceId, sessionId: sessionId, generation: generation)
  }
  init(playerId: Int64, surfaceId: Int64, sessionId: String, generation: Int64) {
    self.playerId = playerId; self.surfaceId = surfaceId
    self.sessionId = sessionId; self.generation = generation
  }
  init(_ value: AppleProtectedSurfaceMessage) {
    self.init(playerId: value.playerId, surfaceId: value.surfaceId,
      sessionId: value.sessionId, generation: value.generation)
  }
}

/// Main-thread ownership only. An unpublished candidate never lends its player.
final class YlFairPlayViewRegistry {
  private var next: Int64 = 0
  private var records: [Int64: YlFairPlayViewRecord] = [:]
  func allocate(playerId: Int64, sessionId: String) throws -> YlFairPlaySurfaceIdentity {
    guard next < Int64.max else { throw YlFairPlayFailure.error("resource.exhausted") }
    next += 1
    return .init(playerId: playerId, surfaceId: next, sessionId: sessionId, generation: next)
  }
  func register(_ id: YlFairPlaySurfaceIdentity) -> YlFairPlayViewRecord {
    let record = YlFairPlayViewRecord(id: id)
    record.onRetire = { [weak self, weak record] in
      if self?.records[id.surfaceId] === record { self?.records.removeValue(forKey: id.surfaceId) }
    }
    records[id.surfaceId] = record
    return record
  }
  func lookup(_ id: YlFairPlaySurfaceIdentity) -> YlFairPlayViewRecord? {
    guard let record = records[id.surfaceId], record.identity == id, record.committed else { return nil }
    return record
  }
}

final class YlFairPlayViewRecord {
  let identity: YlFairPlaySurfaceIdentity
  private(set) var committed = false
  private(set) var revision: Int64 = 0
  private(set) var layer: AVPlayerLayer?
  private var player: AVPlayer?
  private weak var container: CALayer?
  private var viewId: Int64?
  private var retired = false
  private var presentedRevision: Int64?
  private var observation: NSKeyValueObservation?
  var onFrame: ((AppleProtectedViewAck) -> Void)?
  var onRetire: (() -> Void)?
  init(id: YlFairPlaySurfaceIdentity) { identity = id }
  func commit() { if !retired { committed = true } }
  func setPlayer(_ player: AVPlayer?) {
    guard !retired else { return }
    self.player = player
    rebuild()
  }
  func mount(viewId: Int64, container: CALayer) -> Bool {
    guard committed, !retired, self.viewId == nil else { return false }
    self.viewId = viewId; self.container = container
    rebuild()
    return true
  }
  func layout() { layer?.frame = container?.bounds ?? .zero }
  private func rebuild() {
    observation = nil
    layer?.player = nil
    layer?.removeFromSuperlayer()
    layer = nil
    presentedRevision = nil
    guard revision < Int64.max else { retire(); return }
    revision += 1
    guard let container, let player, committed, !retired else { return }
    let next = AVPlayerLayer(player: player)
    next.videoGravity = .resizeAspect
    next.isHidden = true
    next.frame = container.bounds
    container.addSublayer(next)
    layer = next
    let epoch = revision
    observation = next.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
      DispatchQueue.main.async { [weak self, weak layer] in
        guard let layer, layer.isReadyForDisplay else { return }
        self?.presented(layer: layer, revision: epoch)
      }
    }
  }
  /// Called only for readiness of the current layer; test seam avoids protected fixtures.
  func presented(layer: AVPlayerLayer, revision: Int64) {
    guard !retired, committed, self.layer === layer, self.revision == revision,
          player != nil, viewId != nil, presentedRevision != revision else { return }
    presentedRevision = revision
    layer.isHidden = false
    if let viewId, let ack = try? ack(viewId: viewId) { onFrame?(ack) }
  }
  func ack(viewId: Int64) throws -> AppleProtectedViewAck {
    guard !retired, committed, self.viewId == viewId else {
      throw YlFairPlayFailure.error("drm.protection_insufficient")
    }
    return .init(surface: identity.message, viewId: viewId, revision: revision, attached: true)
  }
  @discardableResult func detach(viewId: Int64) -> AppleProtectedViewAck {
    if self.viewId == viewId {
      self.viewId = nil; container = nil; rebuild()
    }
    return .init(surface: identity.message, viewId: viewId, revision: revision, attached: false)
  }
  func retire() {
    guard !retired else { return }
    if let viewId { detach(viewId: viewId) }
    player = nil; retired = true; committed = false; onFrame = nil
    onRetire?(); onRetire = nil
  }
}
