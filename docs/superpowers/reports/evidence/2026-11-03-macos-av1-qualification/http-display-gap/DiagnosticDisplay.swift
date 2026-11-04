// Diagnostic host only. Wrap the existing display driver without changing cadence.
private final class YlAV1DiagnosticDriver: YlDisplayDriving {
  private var driver: (any YlDisplayDriving)!
  private var history: [[String: Any]] = []
  private var previousDrops = 0
  private weak var presentation: YlPresentationCoordinator?
  private var mediaClock: YlMediaClock?
  private var scheduler: YlFrameScheduler?
  var isPaused: Bool {
    get { driver.isPaused }
    set { driver.isPaused = newValue }
  }
  init(make: (@escaping () -> Void) -> any YlDisplayDriving, onTick: @escaping () -> Void) {
    driver = make { [weak self] in
      guard let self else { return }
      if self.presentation == nil, let plugin = YlAV1Capture.plugin,
        let players = Mirror(reflecting: plugin).descendant("registry", "players") as? [String: YlApplePlayerHost],
        let host = players.values.first,
        let coordinator = Mirror(reflecting: host).descendant("coordinator") as? YlAppleSessionCoordinator,
        let slot = Mirror(reflecting: coordinator).descendant("slot") as? YlBackendSlot,
        let session = Mirror(reflecting: slot.current).descendant("session") as? YlManagedPlaybackSession,
        let presentation = Mirror(reflecting: session).descendant("presentation") as? YlPresentationCoordinator {
        self.presentation = presentation
        self.mediaClock = Mirror(reflecting: presentation).descendant("mediaClock") as? YlMediaClock
        self.scheduler = Mirror(reflecting: presentation).descendant("frameScheduler") as? YlFrameScheduler
      }
      let host = DispatchTime.now().uptimeNanoseconds
      var row: [String: Any] = ["hostNs": host, "paused": self.driver.isPaused]
      if let clock = self.mediaClock {
        row["positionUs"] = clock.position(atHostTimeUs: Int64(host / 1000))
      }
      row["pendingPTS"] = self.scheduler?.pendingPTS
      onTick()
      row["endNs"] = DispatchTime.now().uptimeNanoseconds
      if let clock = self.presentation?.isolatedAudioClockStatistics {
        row["clock"] = String(describing: clock)
      }
      let drops = self.scheduler?.lateFrameDropCount ?? 0
      row["drops"] = drops
      self.history.append(row)
      if self.history.count > 120 { self.history.removeFirst() }
      if drops > self.previousDrops {
        print("DIAGNOSTIC_DISPLAY_DROP", String(data: try! JSONSerialization.data(withJSONObject: self.history, options: [.sortedKeys]), encoding: .utf8)!)
      }
      self.previousDrops = drops
    }
  }
  func invalidate() { driver.invalidate() }
}
