#if os(iOS)
import AVFoundation
import Foundation

final class YlIosAudioSession: YlAudioSessionDriving {
  var onInterruption: ((YlAudioInterruption) -> Void)?
  private let session: AVAudioSession
  private let center: NotificationCenter
  private var observer: NSObjectProtocol?
  init(session: AVAudioSession = .sharedInstance(), center: NotificationCenter = .default) {
    self.session = session
    self.center = center
    observer = center.addObserver(forName: AVAudioSession.interruptionNotification,
      object: session, queue: .main) { [weak self] notification in
      guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      if type == .began { self?.onInterruption?(.began) }
      else {
        let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
        self?.onInterruption?(.ended(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)))
      }
    }
  }
  func configureMediaPlayback() throws { try session.setCategory(.playback, mode: .moviePlayback) }
  func activate() throws { try session.setActive(true) }
  func deactivateNotifyingOthers() throws { try session.setActive(false, options: .notifyOthersOnDeactivation) }
  deinit { if let observer { center.removeObserver(observer) } }
}
#endif
