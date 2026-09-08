#if os(macOS)
import AppKit
import Foundation
final class YlMacosLifecycle: YlLifecycleDriving {
  var onSuspend: (() -> Void)?
  var onResume: (() -> Void)?
  var onTerminate: (() -> Void)?
  var onMemoryWarning: (() -> Void)?
  private let center: NotificationCenter
  private var observers: [NSObjectProtocol] = []
  init(center: NotificationCenter = .default) { self.center = center }
  func start() {
    guard observers.isEmpty else { return }
    observers = [
      center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.onSuspend?() },

      center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.onResume?() },

      center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in self?.onTerminate?() }]
  }
  func stop() {
    observers.forEach(center.removeObserver)
    observers.removeAll()
  }
  deinit { stop() }
}

import Foundation

enum YlMacosLifecycleEvent {
  case didResignActive
  case didBecomeActive
  case willTerminate
}

enum YlMacosLifecycleAction: Equatable {
  case preserve
  case emitState
  case disposeAll
}

enum YlMacosLifecyclePolicy {
  static func action(for event: YlMacosLifecycleEvent) -> YlMacosLifecycleAction {
    switch event {
    case .didResignActive:
      return .preserve
    case .didBecomeActive:
      return .emitState
    case .willTerminate:
      return .disposeAll
    }
  }
}
#endif
