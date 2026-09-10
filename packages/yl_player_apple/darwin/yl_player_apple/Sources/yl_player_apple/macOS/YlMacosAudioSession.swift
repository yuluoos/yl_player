#if os(macOS)
import Foundation

/// AVAudioSession has no macOS counterpart. Track package output without changing
/// a system-wide category, route, default device or another application's audio.
final class YlMacosAudioSession: YlAudioSessionDriving {
  var onInterruption: ((YlAudioInterruption) -> Void)?
  private(set) var outputActive = false
  func configureMediaPlayback() throws {}
  func activate() throws { outputActive = true }
  func deactivateNotifyingOthers() throws { outputActive = false }
}
#endif
