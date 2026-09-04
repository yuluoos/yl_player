import Foundation

/// A macOS 12-compatible display cadence used to notify Flutter when a frame
/// is ready. The actual pixel buffer timestamp still comes from the media
/// clock, so timer jitter does not alter playback timing.
final class YlDisplayTimer {
  private let timer: Timer

  var isPaused: Bool {
    get { timer.fireDate == .distantFuture }
    set { timer.fireDate = newValue ? .distantFuture : Date() }
  }

  init(target: Any, selector: Selector, framesPerSecond: Double = 30) {
    timer = Timer(
      timeInterval: 1 / framesPerSecond,
      target: target,
      selector: selector,
      userInfo: nil,
      repeats: true
    )
    RunLoop.main.add(timer, forMode: .common)
  }

  func invalidate() {
    timer.invalidate()
  }
}
