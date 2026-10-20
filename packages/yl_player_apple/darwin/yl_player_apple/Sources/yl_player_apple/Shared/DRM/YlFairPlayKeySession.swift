import yl_player_media_core
import AVFoundation
import Foundation

/// Only opaque binary SPC/CKC crosses this boundary. No key bytes are exported.
struct YlFairPlayExchangeIdentity: Equatable {
  let epoch: Int64
  let requestId: Int64
}
protocol YlFairPlayRequest: AnyObject {
  func makeChallenge(certificate: Data, contentId: Data, completion: @escaping (Result<Data, Error>) -> Void)
  func respond(_ data: Data)
  func reject(_ error: NativePlayerError)
}
enum YlFairPlaySystemFailure { case failed, expired, protection }
struct YlFairPlayDriverEvents {
  let provided: (YlFairPlayRequest) -> Void
  let succeeded: (YlFairPlayRequest) -> Void
  let failed: (YlFairPlayRequest, YlFairPlaySystemFailure) -> Void
}
protocol YlFairPlayDriving: AnyObject {
  /// Must run before the asset starts loading any keys or media metadata.
  func start(asset: AVURLAsset, events: YlFairPlayDriverEvents) throws
  func close()
}

/// Main-owner state machine. A new asset/driver is required after suspension;
/// AVContentKeySession.expire makes its previous recipients inoperable.
final class YlFairPlayKeySession {
  typealias Cancel = () -> Void
  typealias Exchange = (YlFairPlayExchangeIdentity, Data, @escaping (Result<Data, NativePlayerError>) -> Void) -> Cancel
  typealias Schedule = (Int64, @escaping () -> Void) -> Cancel
  private final class Pending {
    enum Stage { case challenge, license, confirmation }
    let request: YlFairPlayRequest
    let identity: YlFairPlayExchangeIdentity
    var stage = Stage.challenge
    var cancelExchange: Cancel?
    var cancelDeadline: Cancel?
    init(_ request: YlFairPlayRequest, _ identity: YlFairPlayExchangeIdentity) {
      self.request = request; self.identity = identity
    }
  }
  private var certificate: Data
  private var contentId: Data
  private let timeoutMs: Int64
  private let makeDriver: () throws -> YlFairPlayDriving
  private let exchange: Exchange
  private let schedule: Schedule
  private let onChange: () -> Void
  private let onFailure: (NativePlayerError) -> Void
  private var driver: YlFairPlayDriving?
  private var epoch: Int64 = 0
  private var serial: Int64 = 0
  private var pending = [ObjectIdentifier: Pending]()
  // Retention prevents pointer reuse from turning a distinct request into a duplicate.
  private var seen = [ObjectIdentifier: YlFairPlayRequest]()
  private var successful = 0
  private let usedAssets = NSHashTable<AVURLAsset>.weakObjects()
  private var terminal = false
  private(set) var isUsable = false

  init(certificate: Data, contentId: Data, timeoutMs: Int64,
       makeDriver: @escaping () throws -> YlFairPlayDriving = { YlFairPlayDriver() },
       schedule: @escaping Schedule = YlFairPlayKeySession.deadline,
       exchange: @escaping Exchange, onChange: @escaping () -> Void,
       onFailure: @escaping (NativePlayerError) -> Void) throws {
    guard (1...65536).contains(certificate.count), (1...8192).contains(contentId.count),
          (1...60000).contains(timeoutMs) else { throw YlFairPlayFailure.error("drm.config_invalid") }
    self.certificate = Data(certificate); self.contentId = Data(contentId)
    self.timeoutMs = timeoutMs; self.makeDriver = makeDriver; self.schedule = schedule
    self.exchange = exchange; self.onChange = onChange; self.onFailure = onFailure
  }

  func start(asset: AVURLAsset) throws {
    precondition(Thread.isMainThread)
    guard !terminal, driver == nil, epoch < Int64.max, !usedAssets.contains(asset) else { throw YlFairPlayFailure.error("drm.session_failed") }
    usedAssets.add(asset)
    epoch += 1
    let currentEpoch = epoch
    let candidate = try makeDriver()
    driver = candidate
    let events = YlFairPlayDriverEvents(provided: { [weak self] request in
      guard let self, self.accepts(currentEpoch) else { return }
      self.provided(request)
    }, succeeded: { [weak self] request in
      guard let self, self.accepts(currentEpoch) else { return }
      self.succeeded(request)
    }, failed: { [weak self] request, reason in
      guard let self, self.accepts(currentEpoch), self.seen[ObjectIdentifier(request)] != nil else { return }
      let code: String
      switch reason {
      case .expired: code = "drm.license_expired"
      case .protection: code = "drm.protection_insufficient"
      case .failed: code = "drm.session_failed"
      }
      self.fail(YlFairPlayFailure.error(code))
    })
    do { try candidate.start(asset: asset, events: events) }
    catch {
      let failure = YlFairPlayFailure.error("drm.session_failed")
      fail(failure); throw failure
    }
  }

  private func accepts(_ value: Int64) -> Bool {
    precondition(Thread.isMainThread)
    return !terminal && driver != nil && epoch == value
  }
  private func owns(_ item: Pending) -> Bool {
    accepts(item.identity.epoch) && pending[ObjectIdentifier(item.request)] === item
  }
  private func provided(_ request: YlFairPlayRequest) {
    let key = ObjectIdentifier(request)
    guard seen[key] == nil else { return }
    guard pending.count < 4, seen.count < 4096, serial < Int64.max else {
      fail(YlFairPlayFailure.error("resource.exhausted")); return
    }
    serial += 1
    let item = Pending(request, .init(epoch: epoch, requestId: serial))
    seen[key] = request; pending[key] = item
    updateReadiness()
    // onChange may synchronously stop/replace this session.
    guard owns(item) else { return }
    let cancel = schedule(timeoutMs) { [weak self, weak item] in
      guard let self, let item, self.owns(item) else { return }
      self.fail(YlFairPlayFailure.error("drm.license_timeout"))
    }
    guard owns(item) else { cancel(); return }
    item.cancelDeadline = cancel
    request.makeChallenge(certificate: certificate, contentId: contentId) { [weak self, weak item] result in
      Self.onOwner {
        guard let self, let item, self.owns(item), item.stage == .challenge else { return }
        switch result {
        case .failure: self.fail(YlFairPlayFailure.error("drm.session_failed"))
        case .success(let challenge):
          guard !challenge.isEmpty, challenge.count <= 1024 * 1024 else {
            self.fail(YlFairPlayFailure.error(challenge.isEmpty ? "drm.config_invalid" : "drm.payload_too_large")); return
          }
          item.stage = .license
          let cancel = self.exchange(item.identity, challenge) { [weak self, weak item] result in
            Self.onOwner {
              guard let self, let item, self.owns(item), item.stage == .license else { return }
              switch result {
              case .failure(let error): self.fail(YlFairPlayFailure.transport(error))
              case .success(let data):
                guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else {
                  self.fail(YlFairPlayFailure.error(data.isEmpty ? "drm.license_response_invalid" : "drm.payload_too_large")); return
                }
                item.stage = .confirmation
                // Set stage before invoking the system, including inline success callbacks.
                item.request.respond(data)
              }
            }
          }
          if self.owns(item) { item.cancelExchange = cancel } else { cancel() }
        }
      }
    }
  }
  private func succeeded(_ request: YlFairPlayRequest) {
    let key = ObjectIdentifier(request)
    guard let item = pending[key], owns(item), item.stage == .confirmation else { return }
    pending.removeValue(forKey: key)
    successful += 1
    item.cancelDeadline?(); item.cancelExchange?()
    updateReadiness()
  }
  private func updateReadiness() {
    let ready = !terminal && driver != nil && successful > 0 && pending.isEmpty
    guard ready != isUsable else { return }
    isUsable = ready; onChange()
  }
  private func fail(_ error: NativePlayerError) {
    guard !terminal else { return }
    terminal = true
    release(error: error)
    wipeConfiguration()
    onFailure(error)
  }
  func suspend() {
    precondition(Thread.isMainThread)
    guard !terminal else { return }
    release(error: YlFairPlayFailure.error("load.cancelled"))
  }
  func close() {
    precondition(Thread.isMainThread)
    guard !terminal else { return }
    terminal = true
    release(error: YlFairPlayFailure.error("load.cancelled"))
    wipeConfiguration()
  }
  private func release(error: NativePlayerError) {
    let readinessChanged = isUsable
    isUsable = false // Reentrant cleanup must never observe keys as still usable.
    let old = driver
    driver = nil // Fence reentrant cancellation and native delegates first.
    let items = Array(pending.values)
    pending.removeAll(); seen.removeAll(); successful = 0
    for item in items {
      item.cancelDeadline?(); item.cancelExchange?()
      item.request.reject(error)
    }
    old?.close()
    if readinessChanged { onChange() }
  }
  private func wipeConfiguration() {
    // Data/system internals may retain copies; this is ownership cleanup, not a
    // claim of physical memory zeroization of every SDK copy.
    certificate.resetBytes(in: 0..<certificate.count); certificate.removeAll()
    contentId.resetBytes(in: 0..<contentId.count); contentId.removeAll()
  }
  deinit {
    let old = driver
    let items = Array(pending.values)
    let cleanup = {
      for item in items {
        item.cancelDeadline?(); item.cancelExchange?()
        item.request.reject(YlFairPlayFailure.error("load.cancelled"))
      }
      old?.close()
    }
    // The owner may be released by a transport's completion queue. Native
    // request operations and expire still execute serially on the main owner.
    if Thread.isMainThread { cleanup() } else { DispatchQueue.main.async(execute: cleanup) }
  }
  static func deadline(_ milliseconds: Int64, _ action: @escaping () -> Void) -> Cancel {
    let work = DispatchWorkItem(block: action)
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(milliseconds)), execute: work)
    return { work.cancel() }
  }
  private static func onOwner(_ action: @escaping () -> Void) {
    if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
  }
}
