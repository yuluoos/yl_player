import AppKit
import Foundation
import QuartzCore

/// Drives video presentation from the active display refresh cadence.
///
/// macOS 14 and newer use the screen-bound display link. Older supported
/// systems retain a run-loop timer fallback at the screen's maximum cadence.
final class YlDisplayTimer {
  private let tickTarget: YlDisplayTickTarget
  private var displayLink: NSObject?
  private var fallbackTimer: Timer?

  var isPaused: Bool {
    get {
      if #available(macOS 14.0, *),
         let displayLink = displayLink as? CADisplayLink {
        return displayLink.isPaused
      }
      return fallbackTimer?.fireDate == .distantFuture
    }
    set {
      if #available(macOS 14.0, *),
         let displayLink = displayLink as? CADisplayLink {
        displayLink.isPaused = newValue
      }
      fallbackTimer?.fireDate = newValue ? .distantFuture : Date()
    }
  }

  init(
    fallbackFramesPerSecond: Double = 60,
    onTick: @escaping () -> Void
  ) {
    precondition(fallbackFramesPerSecond > 0)
    tickTarget = YlDisplayTickTarget(onTick: onTick)

    if #available(macOS 14.0, *), let screen = NSScreen.main {
      let link = screen.displayLink(
        target: tickTarget,
        selector: #selector(YlDisplayTickTarget.displayLinkTick(_:))
      )
      link.add(to: .main, forMode: .common)
      displayLink = link
      return
    }

    let screenFramesPerSecond = Double(
      NSScreen.main?.maximumFramesPerSecond ?? 0
    )
    let cadence = max(fallbackFramesPerSecond, screenFramesPerSecond)
    let timer = Timer(
      timeInterval: 1 / cadence,
      repeats: true
    ) { [weak tickTarget] _ in
      tickTarget?.timerTick()
    }
    RunLoop.main.add(timer, forMode: .common)
    fallbackTimer = timer
  }

  func invalidate() {
    if #available(macOS 14.0, *),
       let displayLink = displayLink as? CADisplayLink {
      displayLink.invalidate()
    }
    displayLink = nil
    fallbackTimer?.invalidate()
    fallbackTimer = nil
  }

  deinit {
    invalidate()
  }
}

private final class YlDisplayTickTarget: NSObject {
  private let onTick: () -> Void

  init(onTick: @escaping () -> Void) {
    self.onTick = onTick
  }

  @available(macOS 14.0, *)
  @objc func displayLinkTick(_ displayLink: CADisplayLink) {
    onTick()
  }

  func timerTick() {
    onTick()
  }
}
