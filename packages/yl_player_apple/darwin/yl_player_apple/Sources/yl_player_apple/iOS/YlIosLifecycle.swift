#if os(iOS)
import UIKit
import Foundation
final class YlIosLifecycle: YlLifecycleDriving {
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
      center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.onSuspend?() },

      center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.onResume?() },

      center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in self?.onMemoryWarning?() }]
  }
  func stop() {
    observers.forEach(center.removeObserver)
    observers.removeAll()
  }
  deinit { stop() }
}
#endif
