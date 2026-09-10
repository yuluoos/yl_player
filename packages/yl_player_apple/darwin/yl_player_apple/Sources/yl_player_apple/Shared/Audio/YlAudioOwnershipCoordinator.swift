import Foundation

struct YlAudioOwnershipKey: Hashable {
  let registry: UUID
  let player: String
}

/// The only process-wide playback owner. No session, intent or renderer is stored
/// here. All driver and lease operations execute synchronously on the main actor.
final class YlAudioOwnershipCoordinator {
  static let shared: YlAudioOwnershipCoordinator = {
    #if os(iOS)
    return .init(driver: YlIosAudioSession())
    #else
    return .init(driver: YlMacosAudioSession())
    #endif
  }()
  private let driver: YlAudioSessionDriving
  private var owners = Set<YlAudioOwnershipKey>()
  private var activatedByPackage = false
  private var interrupted = false
  private var needsReactivation = false
  private var listeners = [UUID: (YlAudioInterruption) -> Void]()
  init(driver: YlAudioSessionDriving) {
    self.driver = driver
    driver.onInterruption = { [weak self] event in
      self?.onMain {
        guard let self else { return }
        switch event {
        case .began:
          self.interrupted = true
          self.needsReactivation = self.activatedByPackage
        case .ended: self.interrupted = false
        }
        Array(self.listeners.values).forEach { $0(event) }
      }
    }
  }
  private func onMain<T>(_ body: @MainActor () throws -> T) rethrows -> T {
    if Thread.isMainThread { return try MainActor.assumeIsolated(body) }
    return try DispatchQueue.main.sync { try MainActor.assumeIsolated(body) }
  }
  var ownerCount: Int { onMain { owners.count } }
  func contains(_ key: YlAudioOwnershipKey) -> Bool { onMain { owners.contains(key) } }
  func acquire(_ key: YlAudioOwnershipKey) throws {
    try onMain {
      guard !interrupted else { throw Self.failure() }
      if needsReactivation {
        do { try driver.activate() } catch { throw Self.failure() }
        needsReactivation = false
      }
      guard !owners.contains(key) else { return }
      if owners.isEmpty && !activatedByPackage {
        do { try driver.configureMediaPlayback(); try driver.activate() }
        catch { throw Self.failure() }
        activatedByPackage = true
      }
      owners.insert(key)
    }
  }
  func release(_ key: YlAudioOwnershipKey) {
    onMain { owners.remove(key); deactivateIfUnowned() }
  }
  func releaseRegistry(_ registry: UUID) {
    onMain {
      owners = owners.filter { $0.registry != registry }
      listeners.removeValue(forKey: registry)
      deactivateIfUnowned()
    }
  }
  func observe(_ registry: UUID, handler: @escaping (YlAudioInterruption) -> Void) {
    onMain { listeners[registry] = handler }
  }
  private func deactivateIfUnowned() {
    guard owners.isEmpty, activatedByPackage else { return }
    // A failed release retains proof of our activation so the next last release
    // can retry. Never claim an external activation by reading global state.
    do { try driver.deactivateNotifyingOthers(); activatedByPackage = false; needsReactivation = false }
    catch { }
  }
  private static func failure() -> NativePlayerError {
    NativePlayerError(category: "resource", code: "audio.activation_failed",
      message: "The playback audio session could not be activated.")
  }
}

/// Instance-scoped output authority. Candidate permits exist only during the
/// host's commit transaction, never during private preparation. A retired permit
/// cannot acquire or release the stable registry/Player lease.
final class YlPlayerAudioOwnership {
  struct Transaction {
    let token: UUID
    fileprivate let prior: UUID?
    fileprivate let wasOwned: Bool
  }
  private let coordinator: YlAudioOwnershipCoordinator
  private let key: YlAudioOwnershipKey
  private var current: UUID?
  init(coordinator: YlAudioOwnershipCoordinator, key: YlAudioOwnershipKey) {
    self.coordinator = coordinator; self.key = key
  }
  func beginSession() -> Transaction {
    let transaction = Transaction(token: UUID(), prior: current, wasOwned: coordinator.contains(key))
    current = transaction.token
    return transaction
  }
  func rollback(_ transaction: Transaction) {
    guard current == transaction.token else { return }
    if !transaction.wasOwned { coordinator.release(key) }
    current = transaction.prior
  }
  func acquire(_ token: UUID) throws {
    guard current == token else { throw YlOpenCancellationToken.cancellationError() }
    try coordinator.acquire(key)
  }
  func release(ifCurrent token: UUID) {
    guard current == token else { return }
    stop()
  }
  func stop() { current = nil; coordinator.release(key) }
}
