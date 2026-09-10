import Foundation

enum YlAudioInterruption {
  case began
  case ended(shouldResume: Bool)
}

/// Global state is write-only. External app activity is never evidence that this
/// package owns activation. macOS supplies the same output lifecycle interface.
protocol YlAudioSessionDriving: AnyObject {
  var onInterruption: ((YlAudioInterruption) -> Void)? { get set }
  func configureMediaPlayback() throws
  func activate() throws
  func deactivateNotifyingOthers() throws
}
