import AppKit
import Foundation
import QuartzCore

protocol YlDisplayCadence: AnyObject {
  var isPaused: Bool { get set }
  func invalidate()
}

/// Drives presentation using the screen containing this player's Flutter view.
/// The screen link continues running when the view is hidden so playback state
/// and completion events do not depend on whether the texture is visible.
final class YlDisplayTimer {
  typealias CadenceFactory = (NSScreen?, Double, @escaping () -> Void) -> YlDisplayCadence

  private weak var view: NSView?
  private let fallbackFramesPerSecond: Double
  private let makeCadence: CadenceFactory
  private let onTick: () -> Void
  private var cadence: YlDisplayCadence?
  private var screen: NSScreen?
  private var paused = false
  private var invalidated = false
  private var observers: [NSObjectProtocol] = []

  var isPaused: Bool {
    get { paused || invalidated }
    set {
      paused = newValue
      refreshCadence()
      cadence?.isPaused = newValue
    }
  }

  init(
    view: NSView? = nil,
    fallbackFramesPerSecond: Double = 60,
    cadenceFactory: @escaping CadenceFactory = YlSystemDisplayCadence.init,
    onTick: @escaping () -> Void
  ) {
    precondition(fallbackFramesPerSecond > 0)
    self.view = view
    self.fallbackFramesPerSecond = fallbackFramesPerSecond
    self.makeCadence = cadenceFactory
    self.onTick = onTick
    observers = [
      NotificationCenter.default.addObserver(
        forName: NSWindow.didChangeScreenNotification, object: nil, queue: .main
      ) { [weak self] notification in
        guard let self, let window = notification.object as? NSWindow,
              self.view?.window === window else { return }
        self.refreshCadence(force: true)
      },
      NotificationCenter.default.addObserver(
        forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
      ) { [weak self] _ in self?.refreshCadence(force: true) },
    ]
    refreshCadence()
  }

  private func refreshCadence(force: Bool = false) {
    guard !invalidated else { return }
    let currentScreen: NSScreen?
    if let window = view?.window {
      currentScreen = window.screen
    } else {
      currentScreen = NSScreen.main
    }
    guard force || cadence == nil || screen !== currentScreen else { return }
    cadence?.invalidate()
    screen = currentScreen
    cadence = makeCadence(currentScreen, fallbackFramesPerSecond) { [weak self] in
      guard let self, !self.invalidated else { return }
      self.refreshCadence()
      self.onTick()
    }
    cadence?.isPaused = paused
  }

  func invalidate() {
    invalidated = true
    cadence?.invalidate()
    cadence = nil
    observers.forEach(NotificationCenter.default.removeObserver)
    observers.removeAll()
  }

  deinit { invalidate() }
}

private final class YlSystemDisplayCadence: YlDisplayCadence {
  private let tickTarget: YlDisplayTickTarget
  private var displayLink: NSObject?
  private var fallbackTimer: Timer?

  var isPaused: Bool {
    get {
      if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
        return link.isPaused
      }
      return fallbackTimer?.fireDate == .distantFuture
    }
    set {
      if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
        link.isPaused = newValue
      }
      fallbackTimer?.fireDate = newValue ? .distantFuture : Date()
    }
  }

  init(screen: NSScreen?, fallbackFramesPerSecond: Double, onTick: @escaping () -> Void) {
    tickTarget = YlDisplayTickTarget(onTick: onTick)
    if #available(macOS 14.0, *), let screen {
      let link = screen.displayLink(
        target: tickTarget, selector: #selector(YlDisplayTickTarget.displayLinkTick(_:))
      )
      link.add(to: .main, forMode: .common)
      displayLink = link
      return
    }
    let cadence = max(fallbackFramesPerSecond, Double(screen?.maximumFramesPerSecond ?? 0))
    let timer = Timer(timeInterval: 1 / cadence, repeats: true) { [weak tickTarget] _ in
      tickTarget?.timerTick()
    }
    RunLoop.main.add(timer, forMode: .common)
    fallbackTimer = timer
  }

  func invalidate() {
    if #available(macOS 14.0, *), let link = displayLink as? CADisplayLink {
      link.invalidate()
    }
    displayLink = nil
    fallbackTimer?.invalidate()
    fallbackTimer = nil
  }

  deinit { invalidate() }
}

private final class YlDisplayTickTarget: NSObject {
  private let onTick: () -> Void
  init(onTick: @escaping () -> Void) { self.onTick = onTick }

  @available(macOS 14.0, *)
  @objc func displayLinkTick(_ displayLink: CADisplayLink) { onTick() }
  func timerTick() { onTick() }
}
