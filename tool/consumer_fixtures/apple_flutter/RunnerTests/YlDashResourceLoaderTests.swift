@testable import yl_player_apple
import AVFoundation
import CoreImage
import Network
import XCTest
#if os(iOS)
import UIKit
#endif

private final class DashLoaderProtocol: URLProtocol {
  static let lock = NSLock()
  static var handler: ((DashLoaderProtocol) -> Void)?
  static var requests: [URLRequest] = []
  static func configuration(_ handler: @escaping (DashLoaderProtocol) -> Void) -> URLSessionConfiguration {
    lock.lock(); self.handler = handler; requests = []; lock.unlock()
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DashLoaderProtocol.self]
    return config
  }
  static var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.lock.lock(); Self.requests.append(request); let handler = Self.handler; Self.lock.unlock()
    handler?(self)
  }
  override func stopLoading() {}
  func respond(_ data: Data, status: Int = 200, headers: [String: String] = [:], finalURL: URL? = nil, finish: Bool = true) {
    client?.urlProtocol(self, didReceive: HTTPURLResponse(url: finalURL ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: data)
    if finish { client?.urlProtocolDidFinishLoading(self) }
  }
}

private final class DashLoadingRequest: YlHlsLoadingRequest {
  let url: URL
  var requestedOffset: Int64 = 0
  var currentOffset: Int64 = 0
  var requestedLength = 0
  var requestsAllDataToEnd = true
  var received = Data()
  var error: NativePlayerError?
  var contentType: String?
  var contentLength: Int64 = 0
  var rangeSupported = false
  var finishCount = 0
  var redirectRequest: URLRequest?
  init(_ url: URL) { self.url = url }
  func setContentInformation(contentType: String?, contentLength: Int64, byteRangeAccessSupported: Bool) {
    self.contentType = contentType; self.contentLength = contentLength; rangeSupported = byteRangeAccessSupported
  }
  func redirect(to request: URLRequest) { redirectRequest = request }
  func respond(with data: Data) { received.append(data) }
  func finishLoading() { finishCount += 1 }
  func finishLoading(with error: NativePlayerError) { self.error = error; finishCount += 1 }
}

// Experimental policy for the owned 320/640 fixture only. No production hook.
private enum AbrDiagnosticRecoveryEligibility {
  static func permitsPolicy(peakBitRate: Double, maximumResolution: CGSize, fixedTrackId: String?) -> Bool {
    peakBitRate == 0 && maximumResolution == .zero && fixedTrackId == nil
  }
}

private struct AbrDiagnosticRecoveryPolicy {
  struct Sample {
    let time: Double, generation: Int, allowed: Bool, width: Int
    let position: Double, remaining: Double, bufferAhead: Double
    let bytes: Int64, transfer: Double, requests: Int, overdue: Int
    var intentRevision: UInt64 = 0
    var credentialRevision: UInt64 = 0
  }
  struct Ticket { let id: UUID, generation: Int, attempt: Int, due: Double; let intentRevision: UInt64; let credentialRevision: UInt64 }
  private(set) var attempts = 0
  private(set) var decision: [String: Any] = [:]
  private var generation: Int?
  private var intentRevision: UInt64?
  private var credentialRevision: UInt64?
  private var sawHigh = false
  private var anchor: Sample?
  private var windows = 0
  private var last: Sample?
  private var pending: Ticket?
  private var inFlight: Ticket?
  static func contiguousAhead(position: Double, ranges: [(Double, Double)]) -> Double {
    guard position.isFinite, position >= 0 else { return 0 }
    var end = position
    for range in ranges.filter({ $0.0.isFinite && $0.1.isFinite && $0.1 >= $0.0 }).sorted(by: { $0.0 < $1.0 }) {
      if range.1 < position { continue }
      if range.0 > end { break }
      end = max(end, range.1)
    }
    return max(0, end - position)
  }
  mutating func invalidateIntent() {
    pending = nil; inFlight = nil; anchor = nil; windows = 0; last = nil
  }
  private func eligible(_ s: Sample) -> Bool {
    s.allowed && s.time.isFinite && s.position.isFinite && s.remaining.isFinite &&
      s.bufferAhead.isFinite && s.transfer.isFinite && s.time >= 0 && s.position >= 0 &&
      s.transfer >= 0 && s.bytes >= 0 && s.requests >= 0 && s.remaining >= 20 && s.bufferAhead >= 5
  }
  mutating func observe(_ s: Sample) -> Ticket? {
    var reason = "invalidSample"
    var windowBitrate: Double?
    var windowRequests: Int?
    func finite(_ value: Double) -> Any { value.isFinite ? value as Any : NSNull() }
    defer {
      decision = ["elapsed": finite(s.time), "generation": s.generation, "intentRevision": s.intentRevision, "credentialRevision": s.credentialRevision, "allowed": s.allowed,
        "width": s.width, "position": finite(s.position), "remaining": finite(s.remaining),
        "bufferAhead": finite(s.bufferAhead), "bytes": s.bytes, "transfer": finite(s.transfer),
        "requests": s.requests, "overdue": s.overdue, "reason": reason, "attempts": attempts,
        "qualifiedWindows": windows, "sawHigh": sawHigh,
        "windowBitrate": windowBitrate.map(finite) ?? NSNull(),
        "windowRequests": windowRequests as Any? ?? NSNull(),
        "pendingDue": pending.map { finite($0.due) } ?? NSNull()]
    }
    if generation != s.generation {
      generation = s.generation; sawHigh = false; anchor = nil; windows = 0
      pending = nil; inFlight = nil; last = nil
    }
    if intentRevision != s.intentRevision { intentRevision = s.intentRevision; invalidateIntent() }
    if credentialRevision != s.credentialRevision { credentialRevision = s.credentialRevision; invalidateIntent() }
    guard eligible(s), last.map({ s.time > $0.time && s.position >= $0.position }) ?? true else {
      if !s.allowed { reason = "playbackIneligible" }
      else if s.bufferAhead.isFinite && s.bufferAhead < 5 { reason = "insufficientBuffer" }
      else if s.remaining.isFinite && s.remaining < 20 { reason = "nearEnd" }
      else if eligible(s) { reason = "nonMonotonic" }
      anchor = nil; windows = 0; pending = nil; inFlight = nil; last = nil; return nil
    }
    last = s
    if s.width == 640 { reason = "highOutput"; sawHigh = true; anchor = nil; windows = 0; pending = nil; return nil }
    guard sawHigh, s.width == 320, s.overdue > 0 else { reason = !sawHigh ? "highNotObserved" : (s.width != 320 ? "notLowOutput" : "noOverdue"); anchor = nil; windows = 0; pending = nil; return nil }
    if let pending {
      guard s.time >= pending.due else { reason = "backoff"; return nil }
      reason = "ticketReady"
      self.pending = nil; inFlight = pending; return pending
    }
    guard inFlight == nil, attempts < 2 else { reason = inFlight != nil ? "inFlight" : "budgetExhausted"; return nil }
    guard let start = anchor else { reason = "windowStarted"; anchor = s; return nil }
    guard s.bytes >= start.bytes, s.transfer >= start.transfer, s.requests >= start.requests else {
      reason = "countersReset"; anchor = s; windows = 0; return nil
    }
    guard s.time - start.time >= 8 else { reason = "windowPending"; return nil }
    anchor = s
    let duration = s.transfer - start.transfer
    let bitrate = duration > 0 ? Double(s.bytes - start.bytes) * 8 / duration : 0
    windowBitrate = bitrate; windowRequests = s.requests - start.requests
    guard s.position > start.position, s.requests - start.requests >= 3,
          bitrate.isFinite, bitrate >= 764_000 * 1.25 else {
      reason = s.position <= start.position ? "noProgress" : (s.requests - start.requests < 3 ? "insufficientRequests" : "insufficientBandwidth")
      windows = 0; return nil
    }
    windows += 1
    guard windows >= 2 else { reason = "firstQualifiedWindow"; return nil }
    reason = "reserved"
    attempts += 1; windows = 0; anchor = nil
    pending = Ticket(id: UUID(), generation: s.generation, attempt: attempts,
      due: s.time + (attempts == 1 ? 0.5 : 1.0), intentRevision: s.intentRevision, credentialRevision: s.credentialRevision)
    return nil
  }
  func authorizes(_ ticket: Ticket, _ s: Sample) -> Bool {
    eligible(s) && s.width == 320 && s.generation == ticket.generation && s.intentRevision == ticket.intentRevision && s.credentialRevision == ticket.credentialRevision &&
      inFlight?.id == ticket.id && s.time >= ticket.due && s.time <= ticket.due + 5
  }
  mutating func finish(_ ticket: Ticket) {
    guard inFlight?.id == ticket.id else { return }
    inFlight = nil; anchor = nil; windows = 0
  }
}

private final class AbrHeldMetadataLoader: NSObject, AVAssetResourceLoaderDelegate {
  private let lock = NSLock()
  private var pending: [AVAssetResourceLoadingRequest] = []
  private let started: XCTestExpectation, cancelled: XCTestExpectation
  private var didStart = false, didCancel = false
  private var ownerCancels = 0, terminatedRequests = 0
  var cancellationState: (pending: Int, owner: Int, terminated: Int) {
    lock.lock(); defer { lock.unlock() }; return (pending.count, ownerCancels, terminatedRequests)
  }
  func cancelAll() {
    lock.lock(); let requests = pending; pending.removeAll(); ownerCancels += 1
    let first = !didCancel; didCancel = true; lock.unlock()
    for request in requests { request.finishLoading(with: URLError(.cancelled)) }
    lock.lock(); terminatedRequests += requests.filter { $0.isFinished }.count; lock.unlock()
    if first { cancelled.fulfill() }
  }
  init(started: XCTestExpectation, cancelled: XCTestExpectation) {
    self.started = started; self.cancelled = cancelled
  }
  func resourceLoader(_ loader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
    lock.lock(); pending.append(request)
    let first = !didStart; didStart = true; lock.unlock()
    if first { started.fulfill() }
    return true
  }
  func resourceLoader(_ loader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
    lock.lock(); pending.removeAll { $0 === request }; terminatedRequests += 1
    let first = !didCancel; didCancel = true; lock.unlock()
    if first { cancelled.fulfill() }
  }
}

// Owned diagnostic experiment only; never a production recovery hook.
private enum AbrDiagnosticCandidatePreparation {
  static func prepareReplacement(originURL: URL, headers: [String: String], credentials: [String: String],
    credentialContext: YlHlsCredentialContext) throws -> YlPreparedHlsAsset {
    try YlPreparedHlsAsset(originURL: originURL, isDash: true, headers: headers,
      credentials: credentials, configuration: .init(map: [:]), cancellationToken: .init(), credentialContext: credentialContext)
  }

  @MainActor static func loadMetadata(_ asset: AVURLAsset, deadlineUptime: Double,
    allowed: () -> Bool = { true }, onStarted: () -> Void = {},
    cancelPending: () -> Void) async -> String {
    // AVAsset cancellation alone does not guarantee that an owned resource
    // loader has terminated its requests. Every abort releases both owners.
    func abort(_ outcome: String) -> String {
      asset.cancelLoading(); cancelPending(); return outcome
    }
    guard deadlineUptime.isFinite else { return abort("failed") }
    guard !Task.isCancelled, allowed() else { return abort("cancelled") }
    guard ProcessInfo.processInfo.systemUptime < deadlineUptime else { return abort("timedOut") }
    let keys = ["playable", "tracks", "duration"]
    asset.loadValuesAsynchronously(forKeys: keys, completionHandler: {})
    onStarted() // Diagnostic injection only after the loading operation is issued.
    while !Task.isCancelled {
      guard allowed() else { return abort("cancelled") }
      guard ProcessInfo.processInfo.systemUptime < deadlineUptime else {
        return abort("timedOut")
      }
      var allLoaded = true
      for key in keys {
        var error: NSError?
        switch asset.statusOfValue(forKey: key, error: &error) {
        case .loaded: break
        case .failed:
          return abort("failed")
        case .cancelled:
          return abort("cancelled")
        case .unknown, .loading: allLoaded = false
        @unknown default:
          return abort("failed")
        }
      }
      if allLoaded {
        guard !Task.isCancelled, allowed() else { return abort("cancelled") }
        guard ProcessInfo.processInfo.systemUptime < deadlineUptime else { return abort("timedOut") }
        if asset.isPlayable { return "loaded" }
        return abort("unplayable")
      }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return abort("cancelled")
  }
}

// Completion callbacks may arrive on AVFoundation queues after cancellation.
private final class AbrPrerollCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Bool?
  func finish(_ result: Bool) { lock.lock(); value = result; lock.unlock() }
  var result: Bool? { lock.lock(); defer { lock.unlock() }; return value }
}

// Diagnostic only: the final backend still performs its exact resume seek.
private enum AbrDiagnosticPreroll {
  @MainActor static func prepare(_ asset: AVURLAsset, position: CMTime, deadlineUptime: Double,
    allowed: () -> Bool, onReady: @escaping @MainActor () async -> Void = {},
    onOperationStarted: (String) -> Void = { _ in }, cancelPending: () -> Void) async
    -> (outcome: String, item: AVPlayerItem?, detached: Bool, stage: String, reusesPrerolledItem: Bool, readyCommand: Task<Void, Never>?) {
    var candidate: AVPlayer?
    var readyCommand: Task<Void, Never>?
    var stage = "beforeLoading"
    func finish(_ outcome: String, item: AVPlayerItem? = nil)
      -> (outcome: String, item: AVPlayerItem?, detached: Bool, stage: String, reusesPrerolledItem: Bool, readyCommand: Task<Void, Never>?) {
      let reusesPrerolledItem = item != nil && item === candidate?.currentItem
      candidate?.pause(); candidate?.cancelPendingPrerolls()
      candidate?.currentItem?.cancelPendingSeeks()
      candidate?.replaceCurrentItem(with: nil)
      if item == nil { asset.cancelLoading(); cancelPending() }
      return (outcome, item, candidate?.currentItem == nil, stage, reusesPrerolledItem, readyCommand)
    }
    func rejection() -> String? {
      if Task.isCancelled || !allowed() { return "cancelled" }
      if ProcessInfo.processInfo.systemUptime >= deadlineUptime { return "timedOut" }
      return nil
    }
    guard deadlineUptime.isFinite, CMTimeGetSeconds(position).isFinite,
      CMTimeGetSeconds(position) >= 0 else { return finish("failed") }
    if let reason = rejection() { return finish(reason) }
    let player = AVPlayer()
    player.isMuted = true; player.allowsExternalPlayback = false
    let item = AVPlayerItem(asset: asset)
    item.preferredForwardBufferDuration = 10
    item.preferredPeakBitRate = 0
    candidate = player
    player.replaceCurrentItem(with: item)
    stage = "waitingReady"
    while player.status != .readyToPlay || item.status != .readyToPlay {
      if let reason = rejection() { return finish(reason) }
      if player.status == .failed || item.status == .failed { return finish("failed") }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    if let reason = rejection() { return finish(reason) }
    let commandCompletion = AbrPrerollCompletion()
    // Public commands have independent ownership. Keep enforcing the candidate's
    // deadline while they wait; the caller joins this task after recording cleanup.
    readyCommand = Task { @MainActor in
      await onReady()
      commandCompletion.finish(true)
    }
    while commandCompletion.result == nil {
      if let reason = rejection() { return finish(reason) }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    if let reason = rejection() { return finish(reason) }
    stage = "seeking"
    let seek = AbrPrerollCompletion()
    player.seek(to: position, toleranceBefore: .zero, toleranceAfter: .zero) { seek.finish($0) }
    onOperationStarted(stage)
    while seek.result == nil {
      if let reason = rejection() { return finish(reason) }
      if player.status == .failed || item.status == .failed { return finish("failed") }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    guard seek.result == true else { return finish("seekFailed") }
    if let reason = rejection() { return finish(reason) }
    // SDK contract: preroll throws unless the player is ready and rate is zero.
    guard player.status == .readyToPlay, item.status == .readyToPlay, player.rate == 0 else {
      return finish("failed")
    }
    stage = "preroll"
    let preroll = AbrPrerollCompletion()
    player.preroll(atRate: 1) { preroll.finish($0) }
    onOperationStarted(stage)
    while preroll.result == nil {
      if let reason = rejection() { return finish(reason) }
      if player.status == .failed || item.status == .failed { return finish("failed") }
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    if let reason = rejection() { return finish(reason) }
    guard preroll.result == true else { return finish("prerollFailed") }
    stage = "ready"
    // A detached, prerolled AVPlayerItem still raised a cross-player association
    // exception on the physical device. Never transfer it. Only share the asset;
    // a fresh item must perform the backend's normal exact resume seek again.
    return finish("ready", item: AVPlayerItem(asset: asset))
  }
}

private enum AbrDiagnosticCaptureURL {
  static func permits(_ url: URL, ownedHost: String?) -> Bool {
    guard url.scheme == "http", url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil, url.path == "/manifest.mpd",
      let port = url.port, (1...65535).contains(port) else { return false }
    guard let ownedHost else { return url.host == "127.0.0.1" }
    guard url.host == ownedHost else { return false }
    let parts = ownedHost.split(separator: ".", omittingEmptySubsequences: false)
    let octets = parts.compactMap { Int($0) }
    guard parts.count == 4, octets.count == 4,
      zip(parts, octets).allSatisfy({ String($0.1) == $0.0 && (0...255).contains($0.1) }) else { return false }
    return octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1]))
      || (octets[0] == 192 && octets[1] == 168)
  }
}

final class YlDashResourceLoaderTests: XCTestCase {
  @MainActor func testDelayedItemReadinessPreservesAcknowledgedPause() async throws {
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url: frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent(
      "flutter_assets/assets/test_media/format_matrix/mp4-avc-aac.mp4")
    let player = AVPlayer(), output = AppleTestTexture()
    var tick: (() -> Void)?, states = [YlNativeState]()
    let backend = YlAvPlayerBackend(playerId: 995,
      services: .init(platform: .current, textureOutput: output,
        makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player,
      emit: { if case .state(let state) = $0.event { states.append(state) } })
    defer { backend.dispose() }
    try backend.open(.init(uri: media.absoluteString, kind: .file, formatHint: .mp4))
    try await AppleHostCharacterizations.waitFor { states.last?.status == "ready" }
    XCTAssertFalse(backend.playbackIntent, "Initial readiness does not request playback")
    try backend.play()
    try await AppleHostCharacterizations.waitFor({ tick?(); return !output.frames.isEmpty }, timeout: 5)
    try backend.pause()
    try await AppleHostCharacterizations.waitFor { states.last?.status == "paused" }
    let item = try XCTUnwrap(player.currentItem)
    XCTAssertEqual(item.status, .readyToPlay)
    let paused = CMTimeGetSeconds(player.currentTime())
    // Deliver an unchanged ready status after the pause, as a queued KVO callback can.
    item.willChangeValue(forKey: "status")
    item.didChangeValue(forKey: "status")
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async { continuation.resume() }
    }
    XCTAssertEqual(states.last?.status, "paused")
    XCTAssertFalse(backend.playbackIntent)
    XCTAssertEqual(player.rate, 0)
    XCTAssertEqual(CMTimeGetSeconds(player.currentTime()), paused, accuracy: 0.05)
    try backend.play()
    try await AppleHostCharacterizations.waitFor({ tick?(); return CMTimeGetSeconds(player.currentTime()) > paused + 0.1 }, timeout: 5)
    XCTAssertTrue(backend.playbackIntent)
  }

  #if os(iOS)
  @MainActor func testAudioRouteLossPausesIntentWithoutNetworkTimeoutAndRequiresExplicitResume() async throws {
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url: frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent(
      "flutter_assets/assets/test_media/format_matrix/mp4-avc-aac.mp4")
    let center = NotificationCenter(), player = AVPlayer(), output = AppleTestTexture()
    var tick: (() -> Void)?, states = [YlNativeState](), failures = [String]()
    let backend = YlAvPlayerBackend(playerId: 994,
      services: .init(platform: .current, textureOutput: output,
        makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player,
      notificationCenter: center,
      emit: {
        if case .state(let state) = $0.event { states.append(state) }
        if case .failure(let error) = $0.event { failures.append(error.code) }
      })
    defer { backend.dispose() }
    try backend.open(.init(uri: media.absoluteString, kind: .file, formatHint: .mp4))
    try backend.play()
    try await AppleHostCharacterizations.waitFor({ tick?(); return !output.frames.isEmpty }, timeout: 5)
    func route(_ reason: AVAudioSession.RouteChangeReason) {
      center.post(name: AVAudioSession.routeChangeNotification, object: nil,
        userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
    }
    route(.newDeviceAvailable); route(.override)
    XCTAssertTrue(backend.playbackIntent, "A new route or override is not a disconnect pause")
    player.pause() // Reproduce AVPlayer's system pause; the private center isolates the notification.
    route(.oldDeviceUnavailable)
    XCTAssertFalse(backend.playbackIntent)
    XCTAssertEqual(states.last?.status, "paused")
    let paused = CMTimeGetSeconds(player.currentTime())
    try await Task.sleep(nanoseconds: 16_000_000_000) // Cross the unchanged default 15-second watchdog.
    tick?()
    XCTAssertTrue(failures.isEmpty)
    XCTAssertFalse(backend.playbackIntent)
    XCTAssertEqual(states.last?.status, "paused")
    XCTAssertEqual(CMTimeGetSeconds(player.currentTime()), paused, accuracy: 0.05)
    route(.newDeviceAvailable)
    XCTAssertFalse(backend.playbackIntent, "Reconnecting a route must not resume playback")
    try backend.play()
    try await AppleHostCharacterizations.waitFor({ tick?(); return CMTimeGetSeconds(player.currentTime()) > paused + 0.1 }, timeout: 5)
    XCTAssertTrue(backend.playbackIntent)
    var reboundStates = [YlNativeState]()
    backend.bindCallbacks { if case .state(let state) = $0.event { reboundStates.append(state) } }
    route(.oldDeviceUnavailable)
    XCTAssertFalse(backend.playbackIntent)
    XCTAssertEqual(reboundStates.last?.status, "paused")
    backend.deactivate()
    let count = reboundStates.count
    route(.oldDeviceUnavailable)
    XCTAssertEqual(reboundStates.count, count, "Inactive output must ignore shared route changes")
    backend.dispose()
    route(.oldDeviceUnavailable)
    XCTAssertEqual(reboundStates.count, count)
  }
  #endif

  @MainActor func testPrerollCandidateCreatesFreshItemAndCancelsAfterRealReadiness() async throws {
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url: frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent(
      "flutter_assets/assets/test_media/format_matrix/mp4-avc-aac.mp4")
    var cleanups = 0
    let result = await AbrDiagnosticPreroll.prepare(AVURLAsset(url: media),
      position: CMTime(value: 1, timescale: 1), deadlineUptime: ProcessInfo.processInfo.systemUptime + 2,
      allowed: { true }, cancelPending: { cleanups += 1 })
    XCTAssertEqual(result.outcome, "ready"); XCTAssertEqual(result.stage, "ready")
    XCTAssertTrue(result.detached); XCTAssertFalse(result.reusesPrerolledItem); XCTAssertEqual(cleanups, 0)
    let item = try XCTUnwrap(result.item)
    let receiving = AVPlayer()
    defer { receiving.pause(); receiving.replaceCurrentItem(with: nil) }
    receiving.isMuted = true; receiving.replaceCurrentItem(with: item)
    let landed = await receiving.seek(to: CMTime(value: 1, timescale: 1), toleranceBefore: .zero, toleranceAfter: .zero)
    XCTAssertTrue(landed)
    receiving.play()
    try await AppleHostCharacterizations.waitFor({ CMTimeGetSeconds(receiving.currentTime()) >= 1.1 }, timeout: 5)
    var allowed = true, readyCalls = 0
    let cancelled = await AbrDiagnosticPreroll.prepare(AVURLAsset(url: media), position: .zero,
      deadlineUptime: ProcessInfo.processInfo.systemUptime + 2, allowed: { allowed },
      onReady: { readyCalls += 1; allowed = false }, cancelPending: { cleanups += 1 })
    XCTAssertEqual(readyCalls, 1); XCTAssertEqual(cancelled.outcome, "cancelled")
    XCTAssertTrue(cancelled.detached); XCTAssertNil(cancelled.item); XCTAssertEqual(cleanups, 1)
  }

  @MainActor func testPrerollRevalidatesIntentAndDeadlineAfterAsyncReadyCommand() async throws {
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url: frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent(
      "flutter_assets/assets/test_media/format_matrix/mp4-avc-aac.mp4")
    for expire in [false, true] {
      var allowed = true, invoked = false, cleanups = 0
      var commandFinished = false, cleanedWhileCommandPending = false
      let release = Task { @MainActor in
        if expire {
          try? await Task.sleep(nanoseconds: 2_200_000_000)
          cleanedWhileCommandPending = cleanups == 1 && !commandFinished
          commandFinished = true
        }
      }
      defer { release.cancel() }
      let result = await AbrDiagnosticPreroll.prepare(AVURLAsset(url: media), position: .zero,
        deadlineUptime: ProcessInfo.processInfo.systemUptime + 2, allowed: { allowed },
        onReady: {
          invoked = true
          if expire {
            while !commandFinished { try? await Task.sleep(nanoseconds: 10_000_000) }
          } else { await Task.yield(); allowed = false; commandFinished = true }
        }, cancelPending: { cleanups += 1 })
      await release.value
      await result.readyCommand?.value
      if expire { XCTAssertTrue(cleanedWhileCommandPending, "Deadline must detach and cancel while the public command is still pending") }
      XCTAssertTrue(invoked, "Must exercise the callback after actual readiness")
      XCTAssertEqual(result.outcome, expire ? "timedOut" : "cancelled")
      XCTAssertEqual(result.stage, "waitingReady")
      XCTAssertTrue(result.detached); XCTAssertNil(result.item); XCTAssertEqual(cleanups, 1)
    }
  }

  func testProductionRecoveryControllerCommitsWithinPreparationDeadline() async throws {
    var now = 0.0
    let controller = YlDashAutoRecoveryController(clock: { now }, schedule: { _, _ in })
    let committed = expectation(description: "current candidate committed")
    let source = YlAppleSourceDescriptor(uri: "https://owned.example/movie.mpd", kind: .network, formatHint: .dash)
    for t in [0.0, 1, 9, 17, 17.5] {
      now = t
      controller.tick(productionSample(t, high: t == 0), prepare: { _ in .avPlayer(source: source) },
        currentSample: { self.productionSample(now) }, commit: { _ in committed.fulfill(); return [:] })
    }
    await fulfillment(of: [committed], timeout: 3)
    XCTAssertEqual(controller.events.count, 1)
    XCTAssertEqual(controller.events.first?["outcome"] as? String, "installed")
    XCTAssertEqual(controller.policy.attempts, 1)
  }

  func testProductionRecoveryControllerCancelsHeldCandidateAndPreservesBudget() async throws {
    for action in ["cancel", "deadline", "credential"] {
      var now = 0.0, credential: UInt64 = 0
      var deadline: (() -> Void)?
      let controller = YlDashAutoRecoveryController(clock: { now }, schedule: { _, callback in deadline = callback })
      let finalized = expectation(description: "candidate finalized " + action)
      controller.onEvent = { _ in finalized.fulfill() }
      let started = expectation(description: "held preparation " + action)
      let released = expectation(description: "cancelled preparation " + action)
      let barrier = DispatchSemaphore(value: 0)
      var installs = 0
      let source = YlAppleSourceDescriptor(uri: "https://owned.example/movie.mpd", kind: .network, formatHint: .dash)
      for t in [0.0, 1, 9, 17, 17.5] {
        now = t
        controller.tick(productionSample(t, high: t == 0), prepare: { token in
          token.onCancel { barrier.signal() }; started.fulfill()
          _ = barrier.wait(timeout: .now() + 3); released.fulfill()
          return .avPlayer(source: source)
        }, currentSample: { self.productionSample(now, credential: credential) }, commit: { _ in installs += 1; return [:] })
      }
      await fulfillment(of: [started], timeout: 2)
      if action == "cancel" { controller.invalidate() }
      else if action == "deadline" { now = 19.501; deadline?() }
      else { credential = 1; barrier.signal() }
      await fulfillment(of: [released], timeout: 2)
      await fulfillment(of: [finalized], timeout: 2)
      XCTAssertEqual(controller.events.count, 1)
      XCTAssertEqual(installs, 0, action)
      XCTAssertEqual(controller.policy.attempts, 1, action)
      XCTAssertNotEqual(controller.events.first?["outcome"] as? String, "installed", action)
      controller.resetForSource()
      XCTAssertEqual(controller.policy.attempts, 0)
    }
  }

  @MainActor func testProductionLoadCommitsRecoveryBudgetBeforeReturningAndFailureKeepsIt() async throws {
    let server = try DashHTTPServer(), data = mpd
    defer { server.close() }
    server.handler = { request in
      (200, [:], request.path == "/bad.mpd" ? Data("<MPD type=\"dynamic\"/>".utf8) : data)
    }
    let controller = YlDashAutoRecoveryController()
    let host = YlApplePlayerHost(playerId: 992, suffix: "production-budget",
      options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 100),
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { AppleClockDisplay(onTick: $0) }),
      callbacks: AppleRecordingCallbacks(), automaticDashRecoveryEnabled: false, dashRecoveryController: controller)
    defer { host.close() }
    try host.attach()
    let first = try await host.load(request: AppleHostFixture.request("reused", url: server.url("/movie.mpd").absoluteString, format: .dash))
    for t in [0.0, 1, 9, 17] {
      controller.tick(productionSample(t, high: t == 0), prepare: { _ in XCTFail("No ticket before backoff"); throw YlOpenCancellationToken.cancellationError() },
        currentSample: { nil }, commit: { _ in XCTFail("No installation"); return [:] })
    }
    XCTAssertEqual(host.dashRecoveryAttempts, 1)
    do {
      _ = try await host.load(request: AppleHostFixture.request("failed", url: server.url("/bad.mpd").absoluteString, format: .dash))
      XCTFail("Malformed candidate must not commit")
    } catch {}
    XCTAssertEqual(host.dashRecoveryAttempts, 1, "Failed Load keeps the surviving source budget")
    let second = try await host.load(request: AppleHostFixture.request("reused", url: server.url("/movie.mpd").absoluteString, format: .dash))
    XCTAssertNotEqual(first.sessionId, second.sessionId)
    XCTAssertEqual(host.dashRecoveryAttempts, 0, "New committed session cannot expose the old budget before the next timer tick")
    XCTAssertTrue(host.dashRecoveryEvents.isEmpty)
  }

  func testProductionRecoveryBudgetUsesCommittedSessionNotReusedRequestLabel() {
    let controller = YlDashAutoRecoveryController()
    let first = YlAppleSessionIdentity(sessionId: "first", loadRequestId: "reused")
    controller.useSource(first)
    for t in [0.0, 1, 9, 17] {
      controller.tick(productionSample(t, high: t == 0), prepare: { _ in XCTFail("No ticket before backoff"); throw YlOpenCancellationToken.cancellationError() },
        currentSample: { nil }, commit: { _ in XCTFail("No installation"); return [:] })
    }
    XCTAssertEqual(controller.policy.attempts, 1)
    controller.invalidate(); controller.useSource(first)
    XCTAssertEqual(controller.policy.attempts, 1)
    controller.useSource(.init(sessionId: "second", loadRequestId: "reused"))
    XCTAssertEqual(controller.policy.attempts, 0, "A new committed Load owns a fresh budget even if its public label is reused")
  }

  func testProductionRecoveryRejectsCounterRegressionInWindowBackoffAndCommit() throws {
    for counter in ["bytes", "transfer", "requests"] {
      func regressed(_ time: Double, to value: Double) -> YlDashAutoRecoveryPolicy.Sample {
        productionSample(time, requests: counter == "requests" ? Int(value) : nil,
          bytes: counter == "bytes" ? Int64(value * 250_000) : nil, transfer: counter == "transfer" ? value : nil)
      }
      var pending = YlDashAutoRecoveryPolicy()
      for t in [0.0, 1, 9, 17] { _ = pending.observe(productionSample(t, high: t == 0)) }
      XCTAssertNil(pending.observe(regressed(17.5, to: 0)), counter)
      XCTAssertEqual(pending.attempts, 1)
      XCTAssertEqual(pending.decision["reason"] as? String, "countersReset")
      var inflight = YlDashAutoRecoveryPolicy()
      for t in [0.0, 1, 9, 17] { _ = inflight.observe(productionSample(t, high: t == 0)) }
      let ticket = try XCTUnwrap(inflight.observe(productionSample(17.5)))
      XCTAssertFalse(inflight.authorizes(ticket, regressed(18, to: 0)), counter)
      var window = YlDashAutoRecoveryPolicy()
      for t in [0.0, 1, 5] { _ = window.observe(productionSample(t, high: t == 0)) }
      _ = window.observe(regressed(6, to: 4)) // Above the window anchor, below the immediately preceding sample.
      XCTAssertEqual(window.decision["reason"] as? String, "countersReset")
      _ = window.observe(productionSample(9))
      XCTAssertEqual(window.decision["qualifiedWindows"] as? Int, 0)
    }
  }

  private func productionSample(_ time: Double, high: Bool = false, bandwidth: Double = 1_500_000,
    allowed: Bool = true, generation: UInt64 = 0, intent: UInt64 = 0, credential: UInt64 = 0,
    buffer: Double = 10, remaining: Double = 90, requests: Int? = nil,
    bytes: Int64? = nil, transfer: Double? = nil) -> YlDashAutoRecoveryPolicy.Sample {
    let low = YlDashAutoRecoveryPolicy.Variant(id: "low", width: 426, height: 240, bandwidth: 400_000)
    let upper = YlDashAutoRecoveryPolicy.Variant(id: "upper", width: 960, height: 540, bandwidth: bandwidth)
    return .init(time: time, generation: generation, allowed: allowed, catalog: [low, upper], current: high ? upper : low,
      position: time, remaining: remaining, bufferAhead: buffer, bytes: bytes ?? Int64(time * 250_000), transfer: transfer ?? time,
      requests: requests ?? Int(time), overdue: 1, intentRevision: intent, credentialRevision: credential)
  }

  func testProductionRecoveryUsesDynamicBandwidthAndTwoWindows() throws {
    var p = YlDashAutoRecoveryPolicy()
    XCTAssertNil(p.observe(productionSample(0, high: true)))
    XCTAssertNil(p.observe(productionSample(1)))
    XCTAssertNil(p.observe(productionSample(9)))
    XCTAssertEqual(p.attempts, 0)
    XCTAssertNil(p.observe(productionSample(17)))
    XCTAssertEqual(p.attempts, 1)
    XCTAssertNil(p.observe(productionSample(17.49)))
    let ticket = try XCTUnwrap(p.observe(productionSample(17.5)))
    XCTAssertEqual(ticket.due, 17.5)
    XCTAssertTrue(p.authorizes(ticket, productionSample(18)))
    // 2 Mbps cannot qualify a 2 Mbps target with the unchanged 1.25 headroom.
    var insufficient = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17, 25, 33] {
      XCTAssertNil(insufficient.observe(productionSample(t, high: t == 0, bandwidth: 2_000_000)))
    }
    XCTAssertEqual(insufficient.attempts, 0)
  }

  func testProductionRecoveryCancellationKeepsBackoffAndSourceBudget() throws {
    var p = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17] { _ = p.observe(productionSample(t, high: t == 0)) }
    let first = try XCTUnwrap(p.observe(productionSample(17.5)))
    p.invalidateIntent()
    XCTAssertFalse(p.authorizes(first, productionSample(18)))
    for t in [18.0, 26, 34] { XCTAssertNil(p.observe(productionSample(t, intent: 1))) }
    XCTAssertEqual(p.attempts, 2)
    XCTAssertNil(p.observe(productionSample(34.99, intent: 1)))
    let second = try XCTUnwrap(p.observe(productionSample(35, intent: 1)))
    XCTAssertEqual(second.due, 35)
    p.finish(second)
    for t in [36.0, 44, 52, 60] { XCTAssertNil(p.observe(productionSample(t, intent: 1))) }
    XCTAssertEqual(p.attempts, 2)
    p = YlDashAutoRecoveryPolicy()
    XCTAssertEqual(p.attempts, 0)
  }

  func testProductionRecoveryRejectsStaleUnsafeAndExpiredCommit() throws {
    var p = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17] { _ = p.observe(productionSample(t, high: t == 0)) }
    let ticket = try XCTUnwrap(p.observe(productionSample(17.5)))
    for s in [productionSample(18, high: true), productionSample(18, allowed: false),
      productionSample(18, generation: 1), productionSample(18, intent: 1), productionSample(18, credential: 1),
      productionSample(18, buffer: 4.999), productionSample(18, remaining: 19.999),
      productionSample(22.501), productionSample(18, bandwidth: 1_600_000)] {
      XCTAssertFalse(p.authorizes(ticket, s))
    }
    XCTAssertTrue(p.authorizes(ticket, productionSample(22.5)))
  }

  func testProductionRecoveryNeedsHighHistoryProgressRequestsAndNaturalHighCancels() throws {
    var p = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17, 25] { XCTAssertNil(p.observe(productionSample(t))) }
    XCTAssertEqual(p.attempts, 0)
    p = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17, 25] { _ = p.observe(productionSample(t, high: t == 0, requests: 1)) }
    XCTAssertEqual(p.attempts, 0)
    p = YlDashAutoRecoveryPolicy()
    for t in [0.0, 1, 9, 17] { _ = p.observe(productionSample(t, high: t == 0)) }
    XCTAssertEqual(p.attempts, 1)
    XCTAssertNil(p.observe(productionSample(17.4, high: true)))
    XCTAssertNil(p.observe(productionSample(17.6)))
    XCTAssertEqual(p.attempts, 1)
  }

  func testFailedPreparationAndRevokedTicketNeverRefundSourceBudget() throws {
    var policy = AbrDiagnosticRecoveryPolicy()
    func sample(_ time: Double, width: Int = 320) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time: time, generation: 0, allowed: true, width: width, position: time,
        remaining: 120 - time, bufferAhead: 10, bytes: Int64(time * 200_000),
        transfer: time, requests: Int(time * 4), overdue: 1)
    }
    _ = policy.observe(sample(0, width: 640))
    for time in [1.0, 9, 17] { XCTAssertNil(policy.observe(sample(time))) }
    let first = try XCTUnwrap(policy.observe(sample(17.5)))
    XCTAssertEqual(first.attempt, 1); XCTAssertEqual(first.due, 17.5)
    policy.invalidateIntent(); policy.finish(first)
    XCTAssertFalse(policy.authorizes(first, sample(18)))
    XCTAssertEqual(policy.attempts, 1)
    for time in [20.0, 28, 36] { XCTAssertNil(policy.observe(sample(time))) }
    XCTAssertNil(policy.observe(sample(36.99)))
    let second = try XCTUnwrap(policy.observe(sample(37)))
    XCTAssertEqual(second.attempt, 2); XCTAssertEqual(second.due, 37)
    policy.finish(second) // The second preparation failed; its budget stays spent.
    for time in 38...99 { XCTAssertNil(policy.observe(sample(Double(time)))) }
    XCTAssertEqual(policy.attempts, 2)
    XCTAssertEqual(policy.decision["reason"] as? String, "budgetExhausted")
  }

  @MainActor func testPrerollCandidateAbortsExpiredDeniedAndRevokedIntent() async {
    let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    for (deadline, allowed, expected) in [(ProcessInfo.processInfo.systemUptime - 1, true, "timedOut"),
                                         (ProcessInfo.processInfo.systemUptime + 2, false, "cancelled")] {
      var cleanups = 0
      let result = await AbrDiagnosticPreroll.prepare(AVURLAsset(url: absent), position: .zero,
        deadlineUptime: deadline, allowed: { allowed }, cancelPending: { cleanups += 1 })
      XCTAssertEqual(result.outcome, expected); XCTAssertNil(result.item)
      XCTAssertTrue(result.detached); XCTAssertEqual(cleanups, 1)
    }
    for mode in ["intent", "task", "deadline"] {
      let started = expectation(description: "preroll enters loader: " + mode)
      let cancelled = expectation(description: "abort releases loader: " + mode)
      let held = AbrHeldMetadataLoader(started: started, cancelled: cancelled)
      let asset = AVURLAsset(url: URL(string: "yl-preroll-test://owned/\(UUID().uuidString)/master.m3u8")!)
      asset.resourceLoader.setDelegate(held, queue: DispatchQueue(label: "yl.preroll.cancel-test"))
      var intent = true
      let loading = Task { @MainActor in
        await AbrDiagnosticPreroll.prepare(asset, position: .zero,
          deadlineUptime: ProcessInfo.processInfo.systemUptime + 2,
          allowed: { intent }, cancelPending: { held.cancelAll() })
      }
      await fulfillment(of: [started], timeout: 1)
      if mode == "intent" { intent = false }
      if mode == "task" { loading.cancel() }
      let result = await loading.value
      XCTAssertEqual(result.outcome, mode == "deadline" ? "timedOut" : "cancelled")
      XCTAssertNil(result.item); XCTAssertTrue(result.detached)
      await fulfillment(of: [cancelled], timeout: 1)
      XCTAssertEqual(held.cancellationState.pending, 0)
      XCTAssertEqual(held.cancellationState.owner, 1)
      XCTAssertGreaterThan(held.cancellationState.terminated, 0)
      withExtendedLifetime(held) {}
    }
  }

  @MainActor func testMetadataPreparationReleasesRequestsWhenIntentIsRevoked() async {
    let started = expectation(description: "real metadata request entered")
    let cancelled = expectation(description: "revocation terminates metadata requests")
    let held = AbrHeldMetadataLoader(started: started, cancelled: cancelled)
    let asset = AVURLAsset(url: URL(string: "yl-intent-test://owned/\(UUID().uuidString)/master.m3u8")!)
    asset.resourceLoader.setDelegate(held, queue: DispatchQueue(label: "yl.metadata.intent"))
    var allowed = true
    let operation = Task { @MainActor in
      await AbrDiagnosticCandidatePreparation.loadMetadata(asset,
        deadlineUptime: ProcessInfo.processInfo.systemUptime + 2,
        allowed: { allowed }, cancelPending: { held.cancelAll() })
    }
    await fulfillment(of: [started], timeout: 1)
    allowed = false
    await fulfillment(of: [cancelled], timeout: 1)
    let result = await operation.value
    XCTAssertEqual(result, "cancelled", "Revoked intent must cancel, not wait for the deadline")
    XCTAssertEqual(held.cancellationState.pending, 0)
    XCTAssertEqual(held.cancellationState.owner, 1)
    XCTAssertGreaterThan(held.cancellationState.terminated, 0)
    withExtendedLifetime(held) {}
  }

  @MainActor func testMetadataPreparationRejectsDeniedIntentAndTaskCancellation() async {
    var cleanups = 0, starts = 0
    let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    let denied = await AbrDiagnosticCandidatePreparation.loadMetadata(AVURLAsset(url: absent),
      deadlineUptime: ProcessInfo.processInfo.systemUptime + 2, allowed: { false },
      onStarted: { starts += 1 }, cancelPending: { cleanups += 1 })
    XCTAssertEqual(denied, "cancelled"); XCTAssertEqual(starts, 0); XCTAssertEqual(cleanups, 1)
    let started = expectation(description: "task-cancel metadata request entered")
    let cancelled = expectation(description: "task cancellation terminates requests")
    let held = AbrHeldMetadataLoader(started: started, cancelled: cancelled)
    let asset = AVURLAsset(url: URL(string: "yl-task-test://owned/\(UUID().uuidString)/master.m3u8")!)
    asset.resourceLoader.setDelegate(held, queue: DispatchQueue(label: "yl.metadata.task"))
    let operation = Task { @MainActor in
      await AbrDiagnosticCandidatePreparation.loadMetadata(asset,
        deadlineUptime: ProcessInfo.processInfo.systemUptime + 2, cancelPending: { held.cancelAll() })
    }
    await fulfillment(of: [started], timeout: 1)
    operation.cancel()
    await fulfillment(of: [cancelled], timeout: 1)
    let result = await operation.value
    XCTAssertEqual(result, "cancelled"); XCTAssertEqual(held.cancellationState.pending, 0)
    XCTAssertEqual(held.cancellationState.owner, 1); XCTAssertGreaterThan(held.cancellationState.terminated, 0)
    withExtendedLifetime(held) {}
  }

  @MainActor func testPrerollPreparationCancelsAfterSeekAndPrerollAreIssued() async throws {
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url: frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent(
      "flutter_assets/assets/test_media/format_matrix/mp4-avc-aac.mp4")
    for target in ["seeking", "preroll"] {
      var allowed = true, injected = 0, cleanups = 0
      let result = await AbrDiagnosticPreroll.prepare(AVURLAsset(url: media),
        position: CMTime(value: 1, timescale: 1), deadlineUptime: ProcessInfo.processInfo.systemUptime + 2,
        allowed: { allowed }, onOperationStarted: { stage in
          if stage == target { injected += 1; allowed = false }
        }, cancelPending: { cleanups += 1 })
      XCTAssertEqual(injected, 1, target); XCTAssertEqual(result.stage, target)
      XCTAssertEqual(result.outcome, "cancelled"); XCTAssertTrue(result.detached)
      XCTAssertNil(result.item); XCTAssertFalse(result.reusesPrerolledItem); XCTAssertEqual(cleanups, 1)
    }
  }

  @MainActor func testCandidateMetadataPreparationRejectsExpiredAndFailedAssets() async {
    let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
    let expiredAsset = AVURLAsset(url: absent)
    var expiredCleanups = 0
    let expired = await AbrDiagnosticCandidatePreparation.loadMetadata(expiredAsset,
      deadlineUptime: ProcessInfo.processInfo.systemUptime - 1, cancelPending: { expiredCleanups += 1 })
    XCTAssertEqual(expiredCleanups, 1)
    XCTAssertEqual(expired, "timedOut")
    var error: NSError?
    XCTAssertEqual(expiredAsset.statusOfValue(forKey: "playable", error: &error), .cancelled,
      "An expired candidate must be cancelled, never reported as loaded")
    var failedCleanups = 0
    let failed = await AbrDiagnosticCandidatePreparation.loadMetadata(AVURLAsset(url: absent),
      deadlineUptime: ProcessInfo.processInfo.systemUptime + 2, cancelPending: { failedCleanups += 1 })
    XCTAssertEqual(failedCleanups, 1)
    XCTAssertEqual(failed, "failed")

    let started = expectation(description: "metadata loading entered real resource loader")
    let cancelled = expectation(description: "deadline cancels pending loading request")
    let held = AbrHeldMetadataLoader(started: started, cancelled: cancelled)
    let asset = AVURLAsset(url: URL(string: "yl-warmup-test://owned/master.m3u8")!)
    asset.resourceLoader.setDelegate(held, queue: DispatchQueue(label: "yl.warmup.deadline-test"))
    let loading = Task { @MainActor in
      await AbrDiagnosticCandidatePreparation.loadMetadata(asset,
        deadlineUptime: ProcessInfo.processInfo.systemUptime + 2, cancelPending: { held.cancelAll() })
    }
    await fulfillment(of: [started], timeout: 1)
    let timedOut = await loading.value
    XCTAssertEqual(timedOut, "timedOut")
    await fulfillment(of: [cancelled], timeout: 1)
    XCTAssertEqual(held.cancellationState.pending, 0)
    XCTAssertEqual(held.cancellationState.owner, 1)
    XCTAssertGreaterThan(held.cancellationState.terminated, 0)
    withExtendedLifetime(held) {}
  }

  func testDeviceCaptureRequiresExplicitOwnedPrivateURL() {
    func permits(_ text: String, _ host: String? = nil) -> Bool {
      AbrDiagnosticCaptureURL.permits(URL(string: text)!, ownedHost: host)
    }
    XCTAssertTrue(permits("http://127.0.0.1:1234/manifest.mpd"))
    XCTAssertTrue(permits("http://192.168.50.196:1234/manifest.mpd", "192.168.50.196"))
    XCTAssertFalse(permits("http://192.168.50.196:1234/manifest.mpd"))
    for host in ["8.8.8.8", "0.0.0.0", "169.254.1.1", "localhost", "172.32.1.1"] {
      XCTAssertFalse(permits("http://\(host):1234/manifest.mpd", host))
    }
    XCTAssertFalse(permits("http://192.168.50.196:1234/manifest.mpd", "192.168.50.197"))
    XCTAssertFalse(permits("http://user@127.0.0.1:1234/manifest.mpd"))
    XCTAssertFalse(permits("http://127.0.0.1:1234/manifest.mpd?other=1"))
    XCTAssertFalse(permits("http://127.0.0.1/manifest.mpd"))
  }

  @MainActor func testPublicTransportRevisionOnlyAdvancesForAcknowledgedCommands() async throws {
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    let loaded = try await fixture.host.load(request: AppleHostFixture.request("intent-revision"))
    let initial = fixture.host.acknowledgedTransportRevision
    XCTAssertThrowsError(try fixture.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: -1)))
    XCTAssertThrowsError(try fixture.host.pause(command: .init(sessionId: "retired")))
    XCTAssertEqual(fixture.host.acknowledgedTransportRevision, initial)
    try fixture.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 1000))
    XCTAssertEqual(fixture.host.acknowledgedTransportRevision, initial + 1)
    try fixture.host.pause(command: .init(sessionId: loaded.sessionId))
    XCTAssertEqual(fixture.host.acknowledgedTransportRevision, initial + 2)
    try fixture.host.setVolume(volume: 0.5)
    XCTAssertEqual(fixture.host.acknowledgedTransportRevision, initial + 2)
    try fixture.host.seekTo(command: .init(sessionId: loaded.sessionId, positionMs: 0))
    XCTAssertEqual(fixture.host.acknowledgedTransportRevision, initial + 3, "Returning to the old position cannot revive old authority")
  }

  func testCredentialCommitFenceOrdersInstallationAndBackgroundStripping() throws {
    let context = YlHlsCredentialContext()
    let before = context.revision
    context.strip("first") // A redirect after the caller sampled, before commit.
    var installed = false
    XCTAssertFalse(context.withUnchangedRevision(before) { installed = true })
    XCTAssertFalse(installed)
    let attempted = DispatchSemaphore(value:0), finished = DispatchSemaphore(value:0)
    let done = expectation(description:"background stripping completes after commit")
    XCTAssertTrue(context.withUnchangedRevision(1) {
      DispatchQueue.global().async {
        attempted.signal(); context.strip("second"); finished.signal(); done.fulfill()
      }
      XCTAssertEqual(attempted.wait(timeout:.now()+1),.success)
      XCTAssertEqual(finished.wait(timeout:.now()+0.05),.timedOut,"Credential change cannot interleave inside accepted installation")
      installed = true
    })
    wait(for:[done],timeout:2)
    XCTAssertTrue(installed); XCTAssertEqual(context.revision,2)
    struct CommitFailure: Error {}
    XCTAssertThrowsError(try context.withUnchangedRevision(2) { throw CommitFailure() })
    context.strip("third"); XCTAssertEqual(context.revision,3,"Thrown commit must release the fence")
  }

  @MainActor func testCredentialFenceCoversActualDashBackendItemInstallation() throws {
    let context = YlHlsCredentialContext(), data = mpd
    let original = try prepare(DashLoaderProtocol.configuration { $0.respond(data) },context:context)
    let candidate = try prepare(DashLoaderProtocol.configuration { $0.respond(data) },context:context)
    defer { candidate.discard() }
    let player = AVPlayer()
    let attempted = DispatchSemaphore(value:0), finished = DispatchSemaphore(value:0)
    let done = expectation(description:"strip completes after backend item commit")
    var replacing = false
    let backend = YlAvPlayerBackend(playerId:995,
      services:.init(platform:.current,textureOutput:AppleTestTexture(),makeDisplayDriver:{ _ in AppleTestDisplay() }),
      configuration:.init(map:["audioPolicy":"appManaged"]),player:player,
      makePlayerItem:{ asset in
        if replacing {
          DispatchQueue.global().async {
            attempted.signal(); context.strip("changed-at-install"); finished.signal(); done.fulfill()
          }
          XCTAssertEqual(attempted.wait(timeout:.now()+1),.success)
          XCTAssertEqual(finished.wait(timeout:.now()+0.05),.timedOut)
        }
        return AVPlayerItem(asset:asset)
      },emit:{ _ in })
    defer { backend.dispose() }
    let source = YlAppleSourceDescriptor(uri:origin.absoluteString,kind:.network,formatHint:.dash)
    try backend.stagePreparedHls(source:source,prepared:original,resume:false)
    try backend.activate()
    let oldItem = try XCTUnwrap(player.currentItem)
    replacing = true
    XCTAssertTrue(try context.withUnchangedRevision(0) { try backend.replaceActiveDash(source:source,prepared:candidate) })
    XCTAssertTrue(player.currentItem !== oldItem)
    wait(for:[done],timeout:2)
    XCTAssertEqual(context.revision,1)
  }

  func testCredentialRevisionIsConcurrentIdempotentAndLoadScoped() {
    let context = YlHlsCredentialContext()
    DispatchQueue.concurrentPerform(iterations: 256) { context.strip("resource-\($0 % 16)") }
    XCTAssertEqual(context.revision,16)
    for index in 0..<16 { XCTAssertTrue(context.isStripped("resource-\(index)")) }
    XCTAssertEqual(YlHlsCredentialContext().revision,0)
  }

  func testRecoveryCredentialRevisionRevokesTicketAndPreservesBudget() throws {
    var policy = AbrDiagnosticRecoveryPolicy()
    func sample(_ time: Double, width: Int = 320, revision: UInt64 = 0) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time: time, generation: 0, allowed: true, width: width, position: time,
        remaining: 120-time, bufferAhead: 10, bytes: Int64(time*200_000), transfer: time,
        requests: Int(time*4), overdue: 1, credentialRevision: revision)
    }
    for (time,width) in [(0.0,640),(1.0,320),(9.0,320),(17.0,320)] { _ = policy.observe(sample(time,width:width)) }
    let old = try XCTUnwrap(policy.observe(sample(17.5)))
    XCTAssertFalse(policy.authorizes(old,sample(17.6,revision:1)), "Credential stripping revokes authority without an item or transport change")
    _ = policy.observe(sample(18,revision:1))
    policy.finish(old)
    XCTAssertEqual(policy.attempts,1)
    _ = policy.observe(sample(26,revision:1)); _ = policy.observe(sample(34,revision:1))
    XCTAssertNil(policy.observe(sample(34.99,revision:1)))
    let next = try XCTUnwrap(policy.observe(sample(35,revision:1)))
    XCTAssertEqual(next.attempt,2); XCTAssertTrue(policy.authorizes(next,sample(35.1,revision:1)))
    XCTAssertFalse(policy.authorizes(old,sample(35.1,revision:1)))
  }

  @MainActor func testPreparedRecoveryCandidateSharesCredentialStrippingAcrossRedirect() async throws {
    let server = try DashHTTPServer(), other = try DashHTTPServer()
    defer { server.close(); other.close() }
    let data = mpd
    server.handler = { request in
      if request.path == "/movie.mpd" { return (200,[:],data) }
      if request.path == "/seg-1.m4s" { return (302,["Location":other.url("/hop").absoluteString],Data()) }
      return (200,[:],Data([1,2,3]))
    }
    other.handler = { _ in (302,["Location":server.url("/return").absoluteString],Data()) }
    let context = YlHlsCredentialContext()
    let current = try YlPreparedHlsAsset(originURL:server.url("/movie.mpd"),isDash:true,
      headers:["Authorization":"fixture","Cookie":"fixture","X-Client":"ordinary"],credentials:["X-Session":"fixture"],
      configuration:.init(map:[:]),cancellationToken:.init(),credentialContext:context)
    defer { current.discard() }
    let candidate = try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL:server.url("/movie.mpd"),
      headers:["Authorization":"fixture","Cookie":"fixture","X-Client":"ordinary"],credentials:["X-Session":"fixture"],credentialContext:context)
    defer { candidate.discard() }
    let cancelledCandidate = try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL:server.url("/movie.mpd"),
      headers:["X-Client":"ordinary"],credentials:["X-Session":"fixture"],credentialContext:context)
    defer { cancelledCandidate.discard() }
    func segment(_ prepared:YlPreparedHlsAsset) throws -> URL {
      let master = read(prepared.loader,prepared.asset.url)
      let video = read(prepared.loader,try child(master.received))
      return try XCTUnwrap(String(decoding:video.received,as:UTF8.self).split(separator:"\n").first { $0.hasPrefix("http:") }.flatMap { URL(string:String($0)) })
    }
    let oldURL = try segment(current), candidateURL = try segment(candidate)
    XCTAssertEqual(context.revision,0)
    var policy = AbrDiagnosticRecoveryPolicy()
    var epoch = ProcessInfo.processInfo.systemUptime
    func sample(_ time: Double, width: Int = 320) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time:time,generation:0,allowed:true,width:width,position:time,remaining:120-time,
        bufferAhead:10,bytes:Int64(time*200_000),transfer:time,requests:Int(time*4),overdue:1,
        credentialRevision:context.revision)
    }
    for (time,width) in [(0.0,640),(1.0,320),(9.0,320),(17.0,320)] { _ = policy.observe(sample(time,width:width)) }
    let ticket = try XCTUnwrap(policy.observe(sample(17.5)))
    epoch = ProcessInfo.processInfo.systemUptime
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url: frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent("flutter_assets/assets/test_media/format_matrix/mp4-avc-aac.mp4")
    var redirectsCompleted = false, cleanups = 0
    let prepared = await AbrDiagnosticPreroll.prepare(AVURLAsset(url:media),position:.zero,
      deadlineUptime:epoch+2,allowed:{ policy.authorizes(ticket,sample(17.5+ProcessInfo.processInfo.systemUptime-epoch)) },
      onReady:{
        do {
          let (_,response) = try await URLSession.shared.data(from:oldURL)
          XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200); redirectsCompleted = true
        } catch { XCTFail("Owned redirect request failed") }
      },cancelPending:{ cleanups += 1; cancelledCandidate.discard() })
    await prepared.readyCommand?.value
    XCTAssertTrue(redirectsCompleted); XCTAssertEqual(prepared.outcome,"cancelled")
    XCTAssertTrue(prepared.detached); XCTAssertNil(prepared.item); XCTAssertEqual(cleanups,1)
    XCTAssertFalse(policy.authorizes(ticket,sample(17.5+ProcessInfo.processInfo.systemUptime-epoch)))
    XCTAssertEqual(policy.attempts,1,"A credential change never refunds the source budget")
    XCTAssertThrowsError(try cancelledCandidate.takeLoader(),"Revocation must consume and cancel the candidate loader")
    XCTAssertEqual(cancelledCandidate.loader.diagnosticProxySnapshot["cancelled"],1)
    XCTAssertTrue(context.isStripped(server.url("/seg-1.m4s").absoluteString))
    XCTAssertEqual(context.revision,1)
    XCTAssertTrue(candidate.loader.credentialContext === context, "A prepared recovery must keep its user Load credential history")
    let (_,nextResponse) = try await URLSession.shared.data(from:candidateURL)
    XCTAssertEqual((nextResponse as? HTTPURLResponse)?.statusCode,200)
    let requests = server.requests.filter { $0.path == "/seg-1.m4s" }
    XCTAssertEqual(requests.count,2); XCTAssertEqual(requests.first?.headers["authorization"],"fixture")
    XCTAssertNil(requests.last?.headers["authorization"]); XCTAssertNil(requests.last?.headers["cookie"])
    XCTAssertNil(requests.last?.headers["x-session"]); XCTAssertEqual(requests.last?.headers["x-client"],"ordinary")
    for r in other.requests + server.requests.filter({ $0.path == "/return" }) {
      XCTAssertNil(r.headers["authorization"]); XCTAssertNil(r.headers["cookie"]); XCTAssertNil(r.headers["x-session"])
    }
    XCTAssertEqual(context.revision,1,"Repeated stripping of the same resource is idempotent")
    XCTAssertEqual(YlHlsCredentialContext().revision,0,"A different user Load has its own history")
  }

  func testRecoveryTicketRejectsAcknowledgedIntentRevisionWithoutItemChange() throws {
    var policy = AbrDiagnosticRecoveryPolicy()
    func sample(_ time: Double, width: Int = 320, revision: UInt64 = 0) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time: time, generation: 0, allowed: true, width: width,
        position: time, remaining: 120 - time, bufferAhead: 10,
        bytes: Int64(time * 200_000), transfer: time, requests: Int(time * 4), overdue: 1,
        intentRevision: revision)
    }
    for (time, width) in [(0.0,640),(1.0,320),(9.0,320),(17.0,320)] { _ = policy.observe(sample(time,width:width)) }
    let ticket = try XCTUnwrap(policy.observe(sample(17.5)))
    XCTAssertTrue(policy.authorizes(ticket, sample(17.6)))
    XCTAssertFalse(policy.authorizes(ticket, sample(17.6, revision: 1)), "An acknowledged forward seek keeps the item but revokes its old ticket")
    _ = policy.observe(sample(18, revision: 1))
    XCTAssertFalse(policy.authorizes(ticket, sample(18.1, revision: 2)), "Pause/resume or a second seek cannot revive old authority")
    XCTAssertEqual(policy.attempts, 1, "Changing accepted intent never refunds source budget")
    _ = policy.observe(sample(26, revision: 1)); _ = policy.observe(sample(34, revision: 1))
    XCTAssertEqual(policy.attempts, 2)
    XCTAssertNil(policy.observe(sample(34.99, revision: 1)))
    let next = try XCTUnwrap(policy.observe(sample(35, revision: 1)))
    XCTAssertEqual(next.attempt, 2)
    XCTAssertTrue(policy.authorizes(next, sample(35.1, revision: 1)))
  }

  func testAutomaticRecoveryCandidateBudgetAndSafety() {
    XCTAssertEqual(AbrDiagnosticRecoveryPolicy.contiguousAhead(position: 10, ranges: [(20, 25)]), 0)
    XCTAssertEqual(AbrDiagnosticRecoveryPolicy.contiguousAhead(position: 10, ranges: [(0, 12), (20, 25)]), 2)
    XCTAssertEqual(AbrDiagnosticRecoveryPolicy.contiguousAhead(position: 10, ranges: [(12, 18), (0, 12)]), 8)
    XCTAssertEqual(AbrDiagnosticRecoveryPolicy.contiguousAhead(position: .nan, ranges: [(0, 20)]), 0)
    var policy = AbrDiagnosticRecoveryPolicy()
    func sample(_ time: Double, generation: Int = 0, allowed: Bool = true, width: Int = 320,
                bytes: Int64? = nil) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time: time, generation: generation, allowed: allowed, width: width,
        position: time, remaining: 120 - time, bufferAhead: 10,
        bytes: bytes ?? Int64(time * 200_000), transfer: time, requests: Int(time * 4), overdue: 1)
    }
    XCTAssertNil(policy.observe(sample(0, width: 640)))
    XCTAssertNil(policy.observe(sample(1)))
    XCTAssertNil(policy.observe(sample(9)))
    XCTAssertNil(policy.observe(sample(17))) // reserve, not execute
    XCTAssertEqual(policy.attempts, 1)
    XCTAssertNil(policy.observe(sample(17.49)))
    let first = policy.observe(sample(17.5))!
    XCTAssertTrue(policy.authorizes(first, sample(17.6)))
    XCTAssertFalse(policy.authorizes(first, sample(17.6, allowed: false)))
    XCTAssertFalse(policy.authorizes(first, sample(17.6, generation: 1)))
    policy.invalidateIntent()
    XCTAssertFalse(policy.authorizes(first, sample(17.7)), "Resume cannot resurrect a cancelled ticket")
    policy.finish(first)
    XCTAssertNil(policy.observe(sample(18, generation: 1, width: 640)))
    XCTAssertNil(policy.observe(sample(19, generation: 1)))
    XCTAssertNil(policy.observe(sample(27, generation: 1)))
    XCTAssertNil(policy.observe(sample(35, generation: 1)))
    XCTAssertEqual(policy.attempts, 2)
    XCTAssertNil(policy.observe(sample(35.99, generation: 1)))
    let second = policy.observe(sample(36, generation: 1))!
    policy.finish(second)
    for time in 37...90 { XCTAssertNil(policy.observe(sample(Double(time), generation: 1))) }
    XCTAssertEqual(policy.attempts, 2, "Successful frames/new item never refund source budget")
    var cancelled = AbrDiagnosticRecoveryPolicy()
    _ = cancelled.observe(sample(0, width: 640)); _ = cancelled.observe(sample(1))
    _ = cancelled.observe(sample(9)); _ = cancelled.observe(sample(17))
    XCTAssertNil(cancelled.observe(sample(17.5, allowed: false)))
    XCTAssertEqual(cancelled.attempts, 1, "Paused/cancelled reservation remains charged")
    var weak = AbrDiagnosticRecoveryPolicy()
    _ = weak.observe(sample(0, width: 640))
    for time in 1...80 { XCTAssertNil(weak.observe(sample(Double(time), bytes: Int64(time * 20_000)))) }
    XCTAssertEqual(weak.attempts, 0)
  }

  func testAutomaticRecoveryCannotReserveUnderDimensionCapsOrFixedSelection() {
    let cases: [(String, Double, CGSize, String?, Int)] = [
      ("automatic", 0, .zero, nil, 1),
      ("bitrate", 500_000, .zero, nil, 0),
      ("width", 0, CGSize(width: 320, height: 100_000), nil, 0),
      ("height", 0, CGSize(width: 100_000, height: 180), nil, 0),
      ("fixed", 0, .zero, "low-track", 0),
    ]
    for (name, peak, resolution, fixed, expectedAttempts) in cases {
      var policy = AbrDiagnosticRecoveryPolicy()
      let allowed = AbrDiagnosticRecoveryEligibility.permitsPolicy(
        peakBitRate: peak, maximumResolution: resolution, fixedTrackId: fixed)
      for time in [0.0, 1, 9, 17, 17.5] {
        _ = policy.observe(.init(time: time, generation: 0, allowed: allowed,
          width: time == 0 ? 640 : 320, position: time + 10, remaining: 110 - time,
          bufferAhead: 10, bytes: Int64(time * 200_000), transfer: time,
          requests: Int(time * 4), overdue: 1))
      }
      XCTAssertEqual(policy.attempts, expectedAttempts, name)
    }
  }

  func testAutomaticRecoveryExplainsUntriggeredWindows() {
    var policy = AbrDiagnosticRecoveryPolicy()
    func sample(_ time: Double, width: Int = 320, allowed: Bool = true, buffer: Double = 10) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time: time, generation: 0, allowed: allowed, width: width, position: time,
        remaining: 120 - time, bufferAhead: buffer, bytes: Int64(time * 90_000),
        transfer: time, requests: Int(time * 4), overdue: 1)
    }
    XCTAssertNil(policy.observe(sample(0, width: 640)))
    XCTAssertEqual(policy.decision["reason"] as? String, "highOutput")
    XCTAssertNil(policy.observe(sample(1)))
    XCTAssertNil(policy.observe(sample(9)))
    XCTAssertEqual(policy.decision["reason"] as? String, "insufficientBandwidth")
    XCTAssertEqual(policy.decision["windowBitrate"] as? Double, 720_000)
    XCTAssertEqual(policy.attempts, 0)
    XCTAssertNil(policy.observe(sample(10, buffer: 4)))
    XCTAssertEqual(policy.decision["reason"] as? String, "insufficientBuffer")
    XCTAssertNil(policy.observe(sample(11, allowed: false)))
    XCTAssertEqual(policy.decision["reason"] as? String, "playbackIneligible")
    XCTAssertEqual(policy.decision["attempts"] as? Int, 0)
  }

  @MainActor
  func testActualOwnedDashAdaptiveObservation() async throws {
    let env = ProcessInfo.processInfo.environment
    guard let rawURL = env["YL_ABR_PROBE_URL"], let rawDirectory = env["YL_ABR_PROBE_DIRECTORY"] else { return }
    let url = try XCTUnwrap(URL(string: rawURL))
    let token = try XCTUnwrap(env["YL_ABR_PROBE_TOKEN"])
    #if os(iOS) && !targetEnvironment(simulator)
    guard env["YL_ABR_PROBE_DEVICE"] == "1", let ownedHost = env["YL_ABR_PROBE_OWNED_HOST"],
      AbrDiagnosticCaptureURL.permits(url, ownedHost: ownedHost),
      token.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else {
      XCTFail("Physical capture requires explicit owned private source and token"); return
    }
    let captureDeviceKind = "physical"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("yl-abr-\(token)", isDirectory: true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    #else
    guard env["YL_ABR_PROBE_DEVICE"] != "1", AbrDiagnosticCaptureURL.permits(url, ownedHost: nil) else {
      XCTFail("Local capture requires loopback source"); return
    }
    let captureDeviceKind = "local"
    let directory = URL(fileURLWithPath: rawDirectory)
    #endif
    let processProof: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
      "executable": ProcessInfo.processInfo.arguments[0], "token": token, "deviceKind": captureDeviceKind]
    try JSONSerialization.data(withJSONObject: processProof, options: [.sortedKeys])
      .write(to: directory.appendingPathComponent("process.json"), options: .atomic)
    let direct = env["YL_ABR_PROBE_DIRECT_HLS"] == "1"
    let programmeSeconds = try XCTUnwrap(Int(env["YL_ABR_PROBE_SECONDS"] ?? "40"))
    XCTAssertTrue([40, 120].contains(programmeSeconds))
    let startupDelayMs = try XCTUnwrap(Int(env["YL_ABR_PROBE_STARTUP_DELAY_MS"] ?? "0"))
    XCTAssertTrue((0...2000).contains(startupDelayMs))
    let recoveryAction = env["YL_ABR_PROBE_RECOVERY_ACTION"] ?? "none"
    let autoScenario = env["YL_ABR_PROBE_AUTO_SCENARIO"] ?? "normal"
    guard ["normal", "pause-first", "pause-during-preparation", "pause-during-metadata", "seek-during-preparation", "caps-during-preparation", "fixed-during-preparation"].contains(autoScenario), autoScenario == "normal" || recoveryAction == "auto-reload" else {
      XCTFail("Invalid automatic recovery scenario"); return
    }
    guard ["none", "seek-current", "reload-source", "auto-reload"].contains(recoveryAction),
          recoveryAction == "none" || (!direct && programmeSeconds == 120) else {
      XCTFail("Invalid recovery diagnostic"); return
    }
    let candidatePreparation = env["YL_ABR_PROBE_CANDIDATE_PREPARATION"] ?? "manifest-only"
    guard ["manifest-only", "asset-metadata", "asset-preroll"].contains(candidatePreparation),
      candidatePreparation == "manifest-only" || (recoveryAction == "auto-reload" && !direct && programmeSeconds == 120) else {
      XCTFail("Invalid candidate preparation diagnostic"); return
    }
    guard autoScenario != "pause-during-metadata" || candidatePreparation == "asset-metadata" else {
      XCTFail("Metadata intent injection requires metadata preparation"); return
    }
    guard !["pause-during-preparation", "seek-during-preparation", "caps-during-preparation", "fixed-during-preparation"].contains(autoScenario) || candidatePreparation == "asset-preroll" else {
      XCTFail("Mid-preparation pause requires preroll"); return
    }
    let publicPolicyCycle = env["YL_ABR_PROBE_PUBLIC_POLICY_CYCLE"] == "1"
    guard !publicPolicyCycle || (!direct && programmeSeconds == 120 && recoveryAction == "none"
      && autoScenario == "normal" && candidatePreparation == "manifest-only" && startupDelayMs == 0) else {
      XCTFail("Public policy cycle requires managed 120s without diagnostic recovery"); return
    }
    let publicPolicyRace = env["YL_ABR_PROBE_PUBLIC_POLICY_RACE"] == "1"
    guard !publicPolicyRace || (!publicPolicyCycle && !direct && programmeSeconds == 120
      && recoveryAction == "auto-reload" && candidatePreparation == "asset-preroll" && startupDelayMs == 0
      && ["caps-during-preparation", "fixed-during-preparation", "pause-during-preparation", "seek-during-preparation"].contains(autoScenario)) else {
      XCTFail("Public policy race requires managed caps/fixed preroll diagnostic"); return
    }
    let productionRecovery = env["YL_ABR_PROBE_PRODUCTION_RECOVERY"] == "1"
    guard !productionRecovery || (captureDeviceKind == "physical" && !direct && !publicPolicyCycle && !publicPolicyRace
      && programmeSeconds == 120 && recoveryAction == "auto-reload" && candidatePreparation == "manifest-only"
      && autoScenario == "normal" && startupDelayMs == 0) else { XCTFail("Invalid production recovery capture"); return }
    let productionCommand = env["YL_ABR_PROBE_PRODUCTION_COMMAND"] ?? "none"
    guard ["none", "pause-resume", "pause-prepared", "seek-prepared", "load-prepared"].contains(productionCommand), productionCommand == "none" || productionRecovery else {
      XCTFail("Invalid production command scenario"); return
    }
    var productionCommandEvents: [String: Any] = [:]
    var productionObservedEvents: [[String: Any]] = []
    let productionBarrier = DispatchSemaphore(value: 0)
    defer { productionBarrier.signal() }
    // The serial preparation queue invokes this only after a real candidate exists.
    // The main queue issues public commands; the production deadline remains 2s.
    var productionPreparedCallback: ((YlOpenCancellationToken) -> Void)?
    var productionCommandTask: Task<Void, Never>?
    defer { productionCommandTask?.cancel() }
    let productionEpoch = ProcessInfo.processInfo.systemUptime
    var productionPolicyFile: FileHandle?
    var productionPolicyWriteFailed = false
    if productionRecovery {
      let path = directory.appendingPathComponent("policy-decisions.jsonl")
      _ = FileManager.default.createFile(atPath: path.path, contents: nil)
      productionPolicyFile = try FileHandle(forWritingTo: path)
    }
    defer { try? productionPolicyFile?.close() }
    func productionEvent(_ input: [String: Any]) -> [String: Any] {
      var result = input
      for key in ["elapsed", "elapsedAfter", "due", "preparationDeadline"] {
        if let value = result[key] as? Double { result[key] = value - productionEpoch }
      }
      return result
    }
    // Preserve the historical managed probe's preparation-before-player order.
    let prepared: YlPreparedHlsAsset?
    if direct || publicPolicyCycle || publicPolicyRace || productionRecovery {
      prepared = nil
      if startupDelayMs > 0 {
        // Explicitly arm the same first-GET clock before the diagnostic delay.
        let (_, response) = try await URLSession.shared.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
      }
    } else {
      do {
        prepared = try await Task.detached {
          try YlPreparedHlsAsset(originURL: url, isDash: true, headers: [:],
            configuration: .init(map: [:]), cancellationToken: .init())
        }.value
      } catch {
        let native = error as? NativePlayerError
        NSLog("[YL-ABR] preparationFailure category=%@ code=%@", native?.category ?? "unknown", native?.code ?? "unknown")
        throw error
      }
    }
    if startupDelayMs > 0 { try await Task.sleep(nanoseconds: UInt64(startupDelayMs) * 1_000_000) }
    let player = AVPlayer()
    var warmedItem: AVPlayerItem?
    let output = AppleTestTexture()
    let presentationTimes = AbrPublishedFrameTimes()
    var tick: (() -> Void)?
    var states: [YlNativeState] = []
    var backendFailure: String?
    var backend: YlAvPlayerBackend?
    var publicHost: YlApplePlayerHost?
    let publicCallbacks = AppleRecordingCallbacks()
    var publicSessionId: String?
    var policyPhase = "initial-auto"
    var publicPolicyEvents: [[String: Any]] = []
    let source = YlAppleSourceDescriptor(uri: url.absoluteString, kind: .network, formatHint: .dash)
    var directOutput: AVPlayerItemVideoOutput?
    var directCompleted = false
    var endTask: Task<Void, Never>?
    defer { endTask?.cancel(); publicHost?.close(); backend?.dispose(); player.pause(); player.replaceCurrentItem(with: nil) }
    if productionCommand.hasSuffix("-prepared") {
      productionPreparedCallback = { token in
        let preparedAt = ProcessInfo.processInfo.systemUptime - productionEpoch
        DispatchQueue.main.async {
          guard productionCommandTask == nil else { productionBarrier.signal(); return }
          productionCommandTask = Task { @MainActor in
            defer { productionBarrier.signal() }
            do {
              let host = try XCTUnwrap(publicHost), session = try XCTUnwrap(publicSessionId)
              let item = player.currentItem, position = CMTimeGetSeconds(player.currentTime())
              let target = Int64(position * 1000) + 1000
              productionCommandEvents = ["sessionId": session, "scenario": productionCommand,
                "candidatePrepared": preparedAt, "commandStarted": ProcessInfo.processInfo.systemUptime - productionEpoch,
                "attemptsAtCommand": host.dashRecoveryAttempts, "positionBefore": position, "targetMs": target]
              if productionCommand == "pause-prepared" {
                try host.pause(command: .init(sessionId: session))
                productionCommandEvents["pausePosition"] = CMTimeGetSeconds(player.currentTime())
                productionCommandEvents["pauseAcknowledged"] = !host.playbackIntent && player.rate == 0
              } else if productionCommand == "seek-prepared" {
                try host.seekTo(command: .init(sessionId: session, positionMs: target))
              } else {
                let loaded = try await host.load(request: AppleHostFixture.request("public-policy-cycle",
                  url: url.absoluteString, format: .dash, autoplay: true, start: target))
                publicSessionId = loaded.sessionId
                productionCommandEvents["newSessionId"] = loaded.sessionId
                productionCommandEvents["newAttempts"] = host.dashRecoveryAttempts
                XCTAssertEqual(host.dashRecoveryAttempts, 0, "Successful Load returns its own recovery budget")
              }
              productionCommandEvents["commandCompleted"] = ProcessInfo.processInfo.systemUptime - productionEpoch
              productionCommandEvents["tokenCancelled"] = token.isCancelled
              productionCommandEvents["itemUnchanged"] = player.currentItem === item
              productionCommandEvents["oldEvents"] = productionObservedEvents
              productionCommandEvents["released"] = ProcessInfo.processInfo.systemUptime - productionEpoch
              productionBarrier.signal()
              if productionCommand == "pause-prepared" {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                productionCommandEvents["beforeResumePosition"] = CMTimeGetSeconds(player.currentTime())
                productionCommandEvents["beforeResumeAttempts"] = host.dashRecoveryAttempts
                productionCommandEvents["itemUnchangedBeforeResume"] = player.currentItem === item
                try await host.play(command: .init(sessionId: session))
                productionCommandEvents["resumeCompleted"] = ProcessInfo.processInfo.systemUptime - productionEpoch
                productionCommandEvents["resumed"] = host.playbackIntent
              }
            } catch { productionCommandEvents["failed"] = true }
            do { try JSONSerialization.data(withJSONObject: productionCommandEvents, options: [.sortedKeys])
              .write(to: directory.appendingPathComponent("production-command-events.json"), options: .atomic) }
            catch { productionPolicyWriteFailed = true }
          }
        }
        _ = productionBarrier.wait(timeout: .now() + 3)
      }
    }
    if publicPolicyCycle || publicPolicyRace || productionRecovery {
      let host = YlApplePlayerHost(playerId: 991, suffix: "abr-public-policy",
        options: .init(decoderPolicy: .systemDefault, audioPolicy: .appManaged, positionUpdateIntervalMs: 100),
        services: .init(platform: .current, textureOutput: output,
          makeDisplayDriver: { tick = $0; return AppleTestDisplay() }), callbacks: publicCallbacks, avPlayer: player, automaticDashRecoveryEnabled: productionRecovery,
        afterDashRecoveryPreparation: productionPreparedCallback,
        makeAvPlayerVideoOutput: { AbrTimestampVideoOutput(attributes: $0, times: presentationTimes) })
      publicHost = host
      if productionRecovery {
        host.onDashRecoveryEvent = { event in productionObservedEvents.append(productionEvent(event)) }
        host.onDashRecoveryDecision = { [weak host] decision in
          var row = decision
          row["sessionId"] = publicSessionId ?? ""
          for key in ["elapsed", "pendingDue"] {
            if let value = row[key] as? Double { row[key] = value - productionEpoch }
          }
          do { try productionPolicyFile?.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])) }
          catch { productionPolicyWriteFailed = true }
          if productionCommand == "pause-resume", productionCommandTask == nil,
            decision["reason"] as? String == "reserved", decision["attempts"] as? Int == 1 {
            productionCommandTask = Task { @MainActor [weak host] in
              do {
                let host = try XCTUnwrap(host), sessionId = try XCTUnwrap(publicSessionId)
                let item = player.currentItem
                productionCommandEvents = ["sessionId": sessionId, "reservationAttempts": host.dashRecoveryAttempts,
                  "pauseStarted": ProcessInfo.processInfo.systemUptime - productionEpoch]
                try host.pause(command: .init(sessionId: sessionId))
                productionCommandEvents["pauseAcknowledged"] = !host.playbackIntent && player.rate == 0
                productionCommandEvents["pausePosition"] = CMTimeGetSeconds(player.currentTime())
                try await Task.sleep(nanoseconds: 2_000_000_000)
                productionCommandEvents["beforeResumePosition"] = CMTimeGetSeconds(player.currentTime())
                productionCommandEvents["beforeResumeAttempts"] = host.dashRecoveryAttempts
                productionCommandEvents["itemUnchangedBeforeResume"] = player.currentItem === item
                productionCommandEvents["installedBeforeResume"] = host.dashRecoveryEvents.contains { $0["outcome"] as? String == "installed" }
                try await host.play(command: .init(sessionId: sessionId))
                productionCommandEvents["resumed"] = host.playbackIntent
                productionCommandEvents["resumeCompleted"] = ProcessInfo.processInfo.systemUptime - productionEpoch
              } catch { productionCommandEvents["failed"] = true }
              do {
                try JSONSerialization.data(withJSONObject: productionCommandEvents, options: [.sortedKeys])
                  .write(to: directory.appendingPathComponent("production-command-events.json"), options: .atomic)
              } catch { productionPolicyWriteFailed = true }
            }
          }
        }
      }
      try host.attach()
      do {
        let loaded = try await host.load(request: AppleHostFixture.request("public-policy-cycle",
          url: url.absoluteString, format: .dash, autoplay: true))
        publicSessionId = loaded.sessionId
      } catch {
        let code = (error as? PigeonError)?.code ?? "unknown"
        NSLog("[YL-ABR] publicHostLoadFailure code=%@", code)
        try JSONSerialization.data(withJSONObject: ["stage": "load", "code": code], options: [.sortedKeys])
          .write(to: directory.appendingPathComponent("public-policy-failure.json"), options: .atomic)
        throw error
      }
    } else if direct {
      // System-only control: same owned media/timelines/constraints; bypass the
      // project's manifest loader, loopback media proxy and backend policies.
      let item = AVPlayerItem(url: url.deletingLastPathComponent().appendingPathComponent("direct-master.m3u8"))
      item.preferredForwardBufferDuration = 10
      item.preferredPeakBitRate = 0
      let pixels = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
      item.add(pixels); directOutput = pixels
      let ended = NotificationCenter.default.notifications(named: .AVPlayerItemDidPlayToEndTime, object: item)
      endTask = Task { @MainActor in
        for await _ in ended { directCompleted = true; break }
      }
      player.replaceCurrentItem(with: item); player.play()
    } else {
      let value = YlAvPlayerBackend(playerId: 991,
        services: .init(platform: .current, textureOutput: output,
          makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), player: player,
        makePlayerItem: { asset in
          if let item = warmedItem, item.asset === asset {
            warmedItem = nil
            return item
          }
          return AVPlayerItem(asset: asset)
        },
        emit: {
          if case .state(let state) = $0.event { states = [state] }
          if case .failure(let error) = $0.event {
            backendFailure = error.code
            NSLog("[YL-ABR] backendFailure category=%@ code=%@", error.category, error.code)
          }
        })
      backend = value
      try value.stagePreparedHls(source: source, prepared: XCTUnwrap(prepared), resume: false)
      try value.activate(); try value.play()
    }
    _ = FileManager.default.createFile(atPath: directory.appendingPathComponent("rows.jsonl").path, contents: nil)
    let file = try FileHandle(forWritingTo: directory.appendingPathComponent("rows.jsonl"))
    defer { try? file.close() }
    let started = productionRecovery ? productionEpoch : ProcessInfo.processInfo.systemUptime
    #if os(iOS)
    let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
    UIApplication.shared.isIdleTimerDisabled = true
    defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
    let notificationCenter = NotificationCenter.default
    let signalsURL = directory.appendingPathComponent("signals.jsonl")
    _ = FileManager.default.createFile(atPath: signalsURL.path, contents: nil)
    let signalsFile = try FileHandle(forWritingTo: signalsURL)
    defer { try? signalsFile.close() }
    var signalWriteFailed = false
    var signalTokens: [NSObjectProtocol] = []
    for (name, kind) in [(AVAudioSession.routeChangeNotification, "audioRoute"),
                         (AVAudioSession.interruptionNotification, "audioInterruption"),
                         (UIApplication.willResignActiveNotification, "willResignActive"),
                         (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
                         (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
                         (UIApplication.willEnterForegroundNotification, "willEnterForeground")] {
      signalTokens.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { notification in
        let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.intValue ?? -1
        let interruption = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.intValue ?? -1
        let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.intValue ?? -1
        NSLog("[YL-ABR] elapsed=%.6f signal=%@ reason=%ld interruption=%ld options=%ld",
          ProcessInfo.processInfo.systemUptime - started, kind, reason, interruption, options)
        let row: [String: Any] = ["elapsed": ProcessInfo.processInfo.systemUptime - started,
          "signal": kind, "reason": reason, "interruption": interruption, "options": options,
          "applicationState": UIApplication.shared.applicationState.rawValue]
        do { try signalsFile.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10])) }
        catch { signalWriteFailed = true }
      })
    }
    defer { signalTokens.forEach(notificationCenter.removeObserver) }
    #endif
    let policyURL = directory.appendingPathComponent("policy-decisions.jsonl")
    var policyFile: FileHandle?
    if recoveryAction == "auto-reload" && !productionRecovery {
      _ = FileManager.default.createFile(atPath: policyURL.path, contents: nil)
      policyFile = try FileHandle(forWritingTo: policyURL)
    }
    defer { try? policyFile?.close() }
    var completed = false
    var frameCount = 0
    var frameGeneration = 0
    var frameItem = player.currentItem
    let frameURL = directory.appendingPathComponent("frame-samples.jsonl")
    _ = FileManager.default.createFile(atPath: frameURL.path, contents: nil)
    let frameFile = try FileHandle(forWritingTo: frameURL)
    defer { try? frameFile.close() }
    var frameWriteFailed = false
    let framePump = Task { @MainActor in
      while !Task.isCancelled {
        if player.currentItem !== frameItem { frameGeneration += 1; frameItem = player.currentItem }
        tick?() // displayLinkTick owns and consumes its retained raster buffer.
        var width = output.frames.last.map { CVPixelBufferGetWidth($0) } ?? 0
        var count = output.frames.count
        let framePresentationTimes: [Any] = output.frames.map {
          presentationTimes.take($0).map { $0 as Any } ?? NSNull()
        }
        output.frames.removeAll(keepingCapacity: true)
        if let pixels = directOutput, pixels.hasNewPixelBuffer(forItemTime: player.currentTime()),
           let buffer = pixels.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
          width = CVPixelBufferGetWidth(buffer); count += 1
        }
        frameCount += count
        let position = CMTimeGetSeconds(player.currentTime())
        let sample: [String: Any] = ["elapsed": ProcessInfo.processInfo.systemUptime - started,
          "generation": frameGeneration, "frames": count, "width": width, "textureClears": output.clears,
          "framePresentationTimes": framePresentationTimes,
          "position": position.isFinite ? position : 0, "rate": player.rate,
          "timeControlStatus": player.timeControlStatus.rawValue,
          "itemStatus": player.currentItem?.status.rawValue ?? -1,
          "resumeSeekPending": backend?.diagnosticResumeSeekPending ?? publicHost?.diagnosticResumeSeekPending ?? false]
        do { try frameFile.write(contentsOf: JSONSerialization.data(withJSONObject: sample, options: [.sortedKeys]) + Data([10])) }
        catch { frameWriteFailed = true; return }
        try? await Task.sleep(nanoseconds: 16_000_000)
      }
    }
    defer { framePump.cancel() }
    var clockAlignment: [String: Double]?
    var sawHigh = false
    var sawDownshift = false
    var recoveryAttempt: [String: Any]?
    var automaticPolicy = AbrDiagnosticRecoveryPolicy()
    var automaticEvents: [[String: Any]] = []
    var resumeTask: Task<Void, Never>?
    var publicResume: [String: Any]?
    defer { resumeTask?.cancel() }
    func currentCredentialContext() -> YlHlsCredentialContext? {
      ((player.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)?.credentialContext
    }
    func automaticSample() -> AbrDiagnosticRecoveryPolicy.Sample {
      let item = player.currentItem
      let position = CMTimeGetSeconds(player.currentTime())
      let logs = item?.accessLog()?.events ?? []
      let buffered = AbrDiagnosticRecoveryPolicy.contiguousAhead(position: position,
        ranges: (item?.loadedTimeRanges ?? []).map {
          (CMTimeGetSeconds($0.timeRangeValue.start), CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)))
        })
      return .init(time: ProcessInfo.processInfo.systemUptime - started, generation: frameGeneration,
        allowed: (backend != nil || publicHost?.playbackIntent == true) && item?.status == .readyToPlay && player.rate > 0 &&
          AbrDiagnosticRecoveryEligibility.permitsPolicy(peakBitRate: item?.preferredPeakBitRate ?? -1,
            maximumResolution: item?.preferredMaximumResolution ?? CGSize(width: -1, height: -1),
            fixedTrackId: publicHost?.initialState.videoSelection?.fixedTrackId ?? backend?.videoSelection.fixedTrackId) && item?.isPlaybackLikelyToKeepUp == true,
        width: Int(item?.presentationSize.width ?? 0), position: position,
        remaining: Double(programmeSeconds) - position, bufferAhead: buffered,
        bytes: logs.reduce(0) { $0 + $1.numberOfBytesTransferred },
        transfer: logs.reduce(0) { $0 + $1.transferDuration },
        requests: logs.reduce(0) { $0 + $1.numberOfMediaRequests },
        overdue: logs.reduce(0) { $0 + $1.downloadOverdue },
        intentRevision: publicHost?.acknowledgedTransportRevision ?? 0,
        credentialRevision: currentCredentialContext()?.revision ?? 0)
    }
    while ProcessInfo.processInfo.systemUptime - started < 140 {
      let item = try XCTUnwrap(player.currentItem)
      if item.presentationSize.width == 640 { sawHigh = true }
      if sawHigh && item.presentationSize.width == 320 { sawDownshift = true }
      func finite(_ value: Double) -> Any { value.isFinite ? value as Any : NSNull() }
      if clockAlignment == nil, item.presentationSize.width > 0 {
        var request = URLRequest(url: url); request.httpMethod = "HEAD"
        let before = (ProcessInfo.processInfo.systemUptime - started) * 1_000_000
        let (_, response) = try await URLSession.shared.data(for: request)
        let after = (ProcessInfo.processInfo.systemUptime - started) * 1_000_000
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Yl-Run-Id"), "abr-accesslog")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Yl-Profile-Sha256"), env["YL_ABR_PROBE_PROFILE_SHA256"])
        let server = try XCTUnwrap(Double(http.value(forHTTPHeaderField: "X-Yl-Elapsed-Us") ?? ""))
        clockAlignment = ["beforeUs": before, "afterUs": after, "serverUs": server]
      }
      let errors: [[String: Any]] = (item.errorLog()?.events ?? []).suffix(32).map {
        let comment = String(($0.errorComment ?? "").prefix(512)).replacingOccurrences(
          of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s]+"#, with: "<url>", options: .regularExpression)
        return ["domain": $0.errorDomain, "code": $0.errorStatusCode, "comment": comment]
      }
      let logs: [[String: Any]] = (item.accessLog()?.events ?? []).map {
        ["observedBitrate": finite($0.observedBitrate), "indicatedBitrate": finite($0.indicatedBitrate),
         "switchBitrate": finite($0.switchBitrate), "transferDuration": finite($0.transferDuration),
         "bytes": $0.numberOfBytesTransferred, "requests": $0.numberOfMediaRequests,
         "segmentsDuration": finite($0.segmentsDownloadedDuration), "stalls": $0.numberOfStalls, "downloadOverdue": $0.downloadOverdue]
      }
      let publicState = publicHost?.initialState
      let fixedTrackId = publicState?.videoSelection?.fixedTrackId ?? backend?.videoSelection.fixedTrackId
      let reachedEnd = publicState.map { $0.status == .completed } ?? (direct ? directCompleted : states.last?.status == "completed")
      let row: [String: Any] = ["elapsed": ProcessInfo.processInfo.systemUptime - started,
        "position": finite(CMTimeGetSeconds(player.currentTime())), "rate": player.rate,
        "status": item.status.rawValue, "width": item.presentationSize.width,
        "height": item.presentationSize.height, "peak": item.preferredPeakBitRate,
        "maximumWidth": item.preferredMaximumResolution.width,
        "maximumHeight": item.preferredMaximumResolution.height,
        "fixedTrackId": fixedTrackId as Any? ?? NSNull(),
        "unconstrainedPolicy": AbrDiagnosticRecoveryEligibility.permitsPolicy(
          peakBitRate: item.preferredPeakBitRate, maximumResolution: item.preferredMaximumResolution,
          fixedTrackId: fixedTrackId),
        "forwardBuffer": item.preferredForwardBufferDuration, "logs": logs,
        "errors": errors, "errorLogEventCount": item.errorLog()?.events.count ?? 0,
        "bufferEmpty": item.isPlaybackBufferEmpty, "bufferFull": item.isPlaybackBufferFull,
        "likelyToKeepUp": item.isPlaybackLikelyToKeepUp, "timeControlStatus": player.timeControlStatus.rawValue,
        "loadedRanges": item.loadedTimeRanges.map { ["start": finite(CMTimeGetSeconds($0.timeRangeValue.start)), "duration": finite(CMTimeGetSeconds($0.timeRangeValue.duration))] },
        "clockAlignment": clockAlignment as Any? ?? NSNull(), "startupDelayMs": startupDelayMs,
        "publicPolicyCycle": publicPolicyCycle, "publicPolicyRace": publicPolicyRace, "policyPhase": policyPhase,
        "publicIntentRevision": publicHost?.acknowledgedTransportRevision as Any? ?? NSNull(),
        "publicPlaybackIntent": publicHost?.playbackIntent as Any? ?? NSNull(),
        "publicResume": publicResume as Any? ?? NSNull(),
        "sessionId": publicHost?.sessionId as Any? ?? NSNull(),
        "acceptedMaximumWidth": publicHost?.acceptedVideoConstraints.maxWidth as Any? ?? NSNull(),
        "acceptedMaximumHeight": publicHost?.acceptedVideoConstraints.maxHeight as Any? ?? NSNull(),
        "acceptedMaximumBitrate": publicHost?.acceptedVideoConstraints.maxBitrate as Any? ?? NSNull(),
        "hostStatus": publicState.map { String(describing: $0.status) } as Any? ?? NSNull(),
        "hostFailureCount": publicCallbacks.failures.count,
        "candidatePreparation": candidatePreparation,
        "recoveryAction": recoveryAction, "recoveryAttempt": recoveryAttempt as Any? ?? NSNull(),
        "frameSamplingVersion": 2, "automaticAttempts": productionRecovery ? (publicHost?.dashRecoveryAttempts ?? 0) : automaticPolicy.attempts,
        "automaticEvents": productionRecovery ? (publicHost?.dashRecoveryEvents.map(productionEvent) ?? []) : automaticEvents,
        "productionRecovery": productionRecovery, "productionCommand": productionCommand,
        "productionCommandEvents": productionCommandEvents,
        "autoScenario": autoScenario, "textureClears": output.clears, "captureDeviceKind": captureDeviceKind,
        "proxySamplingVersion": 1, "proxy": backend?.diagnosticProxySnapshot ?? publicHost?.diagnosticProxySnapshot ?? [:],
        "sampleUptime": ProcessInfo.processInfo.systemUptime,
        "policySamplingVersion": 2, "backendStatus": states.last?.status as Any? ?? NSNull(),
        "backendFailureCode": backendFailure as Any? ?? NSNull(),
        "completed": reachedEnd, "framesPublished": frameCount,
        "transport": direct ? "direct-hls-control" : "managed-dash", "programmeDurationSeconds": programmeSeconds]
      try file.write(contentsOf: JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
      if reachedEnd { completed = true; break }
      if publicPolicyCycle, let host = publicHost, let sessionId = publicSessionId {
        let schedule: [(String, Double)] = [("caps", 8), ("clear-caps", 24), ("fixed", 50), ("restore-auto", 70)]
        let index = publicPolicyEvents.count
        if index < schedule.count, ProcessInfo.processInfo.systemUptime - started >= schedule[index].1 {
          let phase = schedule[index].0
          var event: [String: Any] = ["phase": phase, "elapsed": ProcessInfo.processInfo.systemUptime - started,
            "applied": false, "sessionId": sessionId]
          let beforeItem = player.currentItem
          publicPolicyEvents.append(event)
          let eventsURL = directory.appendingPathComponent("public-policy-events.json")
          func writeEvents() throws {
            try JSONSerialization.data(withJSONObject: publicPolicyEvents, options: [.sortedKeys]).write(to: eventsURL, options: .atomic)
          }
          try writeEvents()
          do {
            if phase == "caps" || phase == "clear-caps" {
              try await host.setVideoConstraints(command: .init(sessionId: sessionId,
                constraints: .init(maxWidth: phase == "caps" ? 320 : nil)))
            } else {
              let id = phase == "fixed" ? "dash-video-w320-h180-b350000" : nil
              try await host.selectVideoTrack(command: .init(sessionId: sessionId, trackId: id))
            }
            event["applied"] = true
            event["itemChanged"] = player.currentItem !== beforeItem
            event["sessionId"] = host.sessionId
            event["elapsedAfter"] = ProcessInfo.processInfo.systemUptime - started
            policyPhase = phase
          } catch {
            event["elapsedAfter"] = ProcessInfo.processInfo.systemUptime - started
            publicPolicyEvents[index] = event; try writeEvents(); throw error
          }
          publicPolicyEvents[index] = event; try writeEvents()
        }
      }
      XCTAssertNotEqual(item.status, .failed)
      if item.status == .failed { break }
      // Explicit experiment only: never install a wall-clock/error-code retry
      // in production. Preserve pre-operation rows even if preparation fails.
      if ["seek-current", "reload-source"].contains(recoveryAction), recoveryAttempt == nil, sawDownshift,
         item.presentationSize.width == 320,
         ProcessInfo.processInfo.systemUptime - started >= 35,
         item.errorLog()?.events.contains(where: { $0.errorDomain == "CoreMediaErrorDomain" && $0.errorStatusCode == -12889 }) == true {
        let before = CMTimeGetSeconds(player.currentTime())
        var attempt: [String: Any] = ["action": recoveryAction,
          "elapsed": ProcessInfo.processInfo.systemUptime - started,
          "positionBefore": before, "completed": false, "itemChanged": false]
        // Write before awaiting so failures cannot erase the attempted action.
        try JSONSerialization.data(withJSONObject: attempt, options: [.sortedKeys])
          .write(to: directory.appendingPathComponent("recovery-attempt.json"), options: .atomic)
        if recoveryAction == "seek-current" {
          let finished = await player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
          attempt["completed"] = finished
          attempt["itemChanged"] = player.currentItem !== item
        } else {
          let credentials = try XCTUnwrap(currentCredentialContext())
          let replacement = try await Task.detached {
            try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL: url,
              headers: source.headers, credentials: source.credentials, credentialContext: credentials)
          }.value
          try XCTUnwrap(backend).replaceActiveDash(source: source, prepared: replacement)
          attempt["completed"] = true // installation only; landing/output checked in later rows
          attempt["itemChanged"] = player.currentItem !== item
        }
        attempt["elapsedAfter"] = ProcessInfo.processInfo.systemUptime - started
        attempt["positionAfterCall"] = finite(CMTimeGetSeconds(player.currentTime()))
        recoveryAttempt = attempt
        try JSONSerialization.data(withJSONObject: attempt, options: [.sortedKeys])
          .write(to: directory.appendingPathComponent("recovery-attempt.json"), options: .atomic)
      }
      var recoveryTicket: AbrDiagnosticRecoveryPolicy.Ticket?
      if let policyFile {
        recoveryTicket = automaticPolicy.observe(automaticSample())
        try policyFile.write(contentsOf: JSONSerialization.data(withJSONObject: automaticPolicy.decision, options: [.sortedKeys]) + Data([10]))
      }
      if let ticket = recoveryTicket {
        let before = automaticSample()
        var event: [String: Any] = ["attempt": ticket.attempt, "elapsed": before.time,
          "due": ticket.due, "generation": ticket.generation, "ticketIntentRevision": ticket.intentRevision, "ticketCredentialRevision": ticket.credentialRevision, "positionBefore": before.position,
          "outcome": "preparing", "textureClearsBefore": output.clears]
        automaticEvents.append(event)
        let eventsURL = directory.appendingPathComponent("automatic-events.json")
        try JSONSerialization.data(withJSONObject: automaticEvents, options: [.sortedKeys]).write(to: eventsURL, options: .atomic)
        if autoScenario == "pause-first", ticket.attempt == 1 {
          try backend?.pause()
          automaticPolicy.invalidateIntent() // Resume cannot revive this ticket.
          resumeTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 2_000_000_000); try backend?.play() }
            catch { /* Cancellation never restarts disposed output. */ }
          }
        }
        do {
          let credentials = try XCTUnwrap(currentCredentialContext())
          let replacement = try await Task.detached {
            try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL: url,
              headers: source.headers, credentials: source.credentials, credentialContext: credentials)
          }.value
          event["manifestPreparedElapsed"] = ProcessInfo.processInfo.systemUptime - started
          var policyCandidate: YlPreparedHlsAsset?
          var policyFixedId: String?
          defer { policyCandidate?.discard() } // Transferred loader ownership is not cancelled.
          if !publicPolicyRace, ["caps-during-preparation", "fixed-during-preparation"].contains(autoScenario), ticket.attempt == 1 {
            let snapshot = try XCTUnwrap(replacement.loader.dashSnapshot)
            if autoScenario == "fixed-during-preparation" {
              policyFixedId = try XCTUnwrap(replacement.loader.videoCatalog?.tracks(
                at: Int64(CMTimeGetSeconds(player.currentTime()) * 1_000_000)).first { $0.width == 320 }?.id)
            }
            let fixedId = policyFixedId
            let constraints: YlAppleVideoConstraints = autoScenario == "caps-during-preparation"
              ? .init(maxWidth: 320, maxHeight: nil, maxBitrate: nil) : .unconstrained
            let context = replacement.loader.credentialContext
            policyCandidate = try await Task.detached {
              try YlPreparedHlsAsset(originURL: url, isDash: true, videoConstraints: constraints,
                fixedTrackId: fixedId, headers: [:], configuration: .init(map: [:]),
                cancellationToken: .init(), dashSnapshot: snapshot, credentialContext: context)
            }.value
            event["policyCandidatePreparedElapsed"] = ProcessInfo.processInfo.systemUptime - started
          }
          var preparationSucceeded = true
          var freshPreparedItem: AVPlayerItem?
          defer { warmedItem = nil }
          if candidatePreparation == "asset-metadata" {
            // An already invalidated ticket must not start speculative loading.
            if automaticPolicy.authorizes(ticket, automaticSample()) && player.currentItem === item {
              let warmupStarted = ProcessInfo.processInfo.systemUptime
              event["warmupStartedElapsed"] = warmupStarted - started
              event["warmupProxyBefore"] = replacement.loader.diagnosticProxySnapshot
              event["warmupFramesBefore"] = frameCount
              event["warmupPositionBefore"] = finite(CMTimeGetSeconds(player.currentTime()))
              let outcome = await AbrDiagnosticCandidatePreparation.loadMetadata(replacement.asset,
                deadlineUptime: min(warmupStarted + 2, started + ticket.due + 5),
                allowed: { automaticPolicy.authorizes(ticket, automaticSample()) && player.currentItem === item },
                onStarted: {
                  if autoScenario == "pause-during-metadata", ticket.attempt == 1 {
                    automaticPolicy.invalidateIntent()
                    do {
                      try XCTUnwrap(backend).pause()
                      event["metadataPauseApplied"] = true
                      event["metadataPauseElapsed"] = ProcessInfo.processInfo.systemUptime - started
                      resumeTask = Task { @MainActor in
                        do { try await Task.sleep(nanoseconds: 2_000_000_000); try backend?.play() }
                        catch { /* Cancellation cannot resume disposed output. */ }
                      }
                    } catch { event["metadataPauseApplied"] = false }
                  }
                }, cancelPending: { replacement.discard() })
              event["warmupOutcome"] = outcome
              event["warmupCompletedElapsed"] = ProcessInfo.processInfo.systemUptime - started
              event["warmupProxyAfter"] = replacement.loader.diagnosticProxySnapshot
              event["warmupFramesAfter"] = frameCount
              event["warmupPositionAfter"] = finite(CMTimeGetSeconds(player.currentTime()))
              event["warmupOldItemRetained"] = player.currentItem === item
              preparationSucceeded = outcome == "loaded"
            } else { event["warmupOutcome"] = "skippedIneligible" }
          }
          if candidatePreparation == "asset-preroll" {
            let warmupStarted = ProcessInfo.processInfo.systemUptime
            event["warmupStartedElapsed"] = warmupStarted - started
            event["warmupProxyBefore"] = replacement.loader.diagnosticProxySnapshot
            event["warmupFramesBefore"] = frameCount
            event["warmupPositionBefore"] = finite(CMTimeGetSeconds(player.currentTime()))
            event["preparationPauseApplied"] = false
            let warmupDeadline = min(warmupStarted + 2, started + ticket.due + 5)
            event["warmupDeadlineElapsed"] = warmupDeadline - started
            let prepared = await AbrDiagnosticPreroll.prepare(replacement.asset, position: player.currentTime(),
              deadlineUptime: warmupDeadline,
              allowed: { automaticPolicy.authorizes(ticket, automaticSample()) && player.currentItem === item },
              onReady: {
                if publicPolicyRace, ticket.attempt == 1 {
                  event["publicCommandReady"] = true
                  event["publicCommandManuallyInvalidated"] = false
                  event["publicCommandStartedElapsed"] = ProcessInfo.processInfo.systemUptime - started
                  event["publicCommandApplied"] = false
                  do {
                    let host = try XCTUnwrap(publicHost), sessionId = try XCTUnwrap(publicSessionId)
                    event["publicCommandIntentBefore"] = host.acknowledgedTransportRevision
                    let commandPosition = CMTimeGetSeconds(player.currentTime())
                    event["publicCommandPositionBefore"] = finite(commandPosition)
                    if autoScenario == "pause-during-preparation" {
                      try host.pause(command: .init(sessionId: sessionId))
                      event["publicPausePosition"] = finite(CMTimeGetSeconds(player.currentTime()))
                      let pausedElapsed = ProcessInfo.processInfo.systemUptime - started
                      resumeTask = Task { @MainActor in
                        do {
                          try await Task.sleep(nanoseconds: 2_000_000_000)
                          let begin = ProcessInfo.processInfo.systemUptime - started
                          try await host.play(command: .init(sessionId: sessionId))
                          publicResume = ["applied": true, "startedElapsed": begin,
                            "completedElapsed": ProcessInfo.processInfo.systemUptime - started,
                            "pausedElapsed": pausedElapsed, "sessionId": host.sessionId as Any? ?? NSNull(),
                            "itemUnchanged": player.currentItem === item,
                            "oldTicketAuthorized": automaticPolicy.authorizes(ticket, automaticSample())]
                        } catch { publicResume = ["applied": false] }
                      }
                    } else if autoScenario == "seek-during-preparation" {
                      let target = Int64(commandPosition * 1000) + 1000
                      event["publicSeekTargetMs"] = target
                      try host.seekTo(command: .init(sessionId: sessionId, positionMs: target))
                    } else if autoScenario == "caps-during-preparation" {
                      try await host.setVideoConstraints(command: .init(sessionId: sessionId,
                        constraints: .init(maxWidth: 320)))
                    } else {
                      try await host.selectVideoTrack(command: .init(sessionId: sessionId,
                        trackId: "dash-video-w320-h180-b350000"))
                    }
                    event["publicCommandIntentAfter"] = host.acknowledgedTransportRevision
                    event["publicCommandApplied"] = true
                    event["publicCommandSessionId"] = host.sessionId
                    event["publicCommandItemChanged"] = player.currentItem !== item
                  } catch { event["publicCommandApplied"] = false }
                  event["publicCommandCompletedElapsed"] = ProcessInfo.processInfo.systemUptime - started
                  // No invalidateIntent(): actual host policy/item identity must revoke eligibility.
                }
                if !publicPolicyRace, ["caps-during-preparation", "fixed-during-preparation"].contains(autoScenario), ticket.attempt == 1 {
                  automaticPolicy.invalidateIntent()
                  do {
                    let target = try XCTUnwrap(backend)
                    try target.replaceActiveDash(source: source, prepared: XCTUnwrap(policyCandidate),
                      selection: .init(fixedTrackId: policyFixedId, reason: "user"))
                    event["policyChangeApplied"] = true
                    event["policyChangeElapsed"] = ProcessInfo.processInfo.systemUptime - started
                    event["policyChangedItem"] = player.currentItem !== item
                    event["policyFixedTrackId"] = target.videoSelection.fixedTrackId as Any? ?? NSNull()
                    event["policyMaximumWidth"] = player.currentItem?.preferredMaximumResolution.width ?? -1
                    event["policyMaximumHeight"] = player.currentItem?.preferredMaximumResolution.height ?? -1
                  } catch { event["policyChangeApplied"] = false }
                }
                if !publicPolicyRace, autoScenario == "seek-during-preparation", ticket.attempt == 1 {
                  automaticPolicy.invalidateIntent()
                  let target = Int64(CMTimeGetSeconds(player.currentTime()) * 1_000) + 1_000
                  event["preparationSeekTargetMs"] = target
                  do {
                    try XCTUnwrap(backend).seek(toMs: target)
                    event["preparationSeekApplied"] = true
                    event["preparationSeekElapsed"] = ProcessInfo.processInfo.systemUptime - started
                  } catch { event["preparationSeekApplied"] = false }
                }
                if !publicPolicyRace, autoScenario == "pause-during-preparation", ticket.attempt == 1 {
                  try? backend?.pause(); automaticPolicy.invalidateIntent()
                  event["preparationPauseApplied"] = true
                  event["preparationPauseElapsed"] = ProcessInfo.processInfo.systemUptime - started
                  resumeTask = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: 2_000_000_000); try backend?.play() }
                    catch { /* Cancellation cannot resume disposed output. */ }
                  }
                }
              }, cancelPending: { replacement.discard() })
            event["warmupOutcome"] = prepared.outcome
            event["warmupStage"] = prepared.stage
            event["warmupDetached"] = prepared.detached
            event["warmupReusesPrerolledItem"] = prepared.reusesPrerolledItem
            event["warmupCompletedElapsed"] = ProcessInfo.processInfo.systemUptime - started
            event["warmupProxyAfter"] = replacement.loader.diagnosticProxySnapshot
            event["warmupFramesAfter"] = frameCount
            event["warmupPositionAfter"] = finite(CMTimeGetSeconds(player.currentTime()))
            event["warmupOldItemRetained"] = player.currentItem === item
            // Candidate cleanup is already recorded, even if a public command
            // is still finishing. Its late completion cannot change the outcome.
            await prepared.readyCommand?.value
            preparationSucceeded = prepared.outcome == "ready" && prepared.detached && !prepared.reusesPrerolledItem && prepared.item != nil
            freshPreparedItem = prepared.item
          }
          event["preparationCompletedElapsed"] = ProcessInfo.processInfo.systemUptime - started
          if !preparationSucceeded {
            replacement.discard(); event["outcome"] = "preparationFailed"
          } else if publicPolicyRace {
            replacement.asset.cancelLoading(); replacement.discard()
            event["outcome"] = "cancelled"
            event["publicUnexpectedInstallEligibility"] = automaticPolicy.authorizes(ticket, automaticSample()) && player.currentItem === item
          } else if automaticPolicy.authorizes(ticket, automaticSample()) && player.currentItem === item && currentCredentialContext() === credentials {
            // This owned backend has no reentrant credential callbacks. Both
            // DASH loaders have completed preflight; no network wait is allowed
            // in the synchronous replacement. Background strip linearizes
            // either before this fence (reject) or after installation.
            let committed = try credentials.withUnchangedRevision(ticket.credentialRevision) {
              warmedItem = freshPreparedItem
              try XCTUnwrap(backend).replaceActiveDash(source: source, prepared: replacement)
            }
            event["credentialCommitAccepted"] = committed
            if committed {
              if let freshPreparedItem { event["freshPreparedItemInstalled"] = player.currentItem === freshPreparedItem }
              event["outcome"] = "installed"; event["itemChanged"] = player.currentItem !== item
            } else {
              replacement.asset.cancelLoading(); replacement.discard(); event["outcome"] = "cancelled"
            }
          } else {
            replacement.asset.cancelLoading(); replacement.discard(); event["outcome"] = "cancelled"
          }
        } catch { event["outcome"] = "preparationFailed" } // bounded retry, original error rows retained
        event["elapsedAfter"] = ProcessInfo.processInfo.systemUptime - started
        event["textureClearsAfter"] = output.clears
        automaticEvents[automaticEvents.count - 1] = event
        automaticPolicy.finish(ticket)
        try JSONSerialization.data(withJSONObject: automaticEvents, options: [.sortedKeys]).write(to: eventsURL, options: .atomic)
      }
      try await Task.sleep(nanoseconds: 250_000_000)
    }
    XCTAssertTrue(completed)
    framePump.cancel(); await framePump.value
    XCTAssertFalse(frameWriteFailed)
    XCTAssertFalse(productionPolicyWriteFailed)
    if productionCommand.hasSuffix("-prepared") {
      XCTAssertEqual(productionCommandEvents["tokenCancelled"] as? Bool, true)
      XCTAssertNil(productionCommandEvents["failed"])
      XCTAssertEqual((productionCommandEvents["oldEvents"] as? [[String: Any]])?.first?["outcome"] as? String, "cancelled")
    }
    if productionCommand == "pause-resume" {
      XCTAssertEqual(productionCommandEvents["pauseAcknowledged"] as? Bool, true)
      XCTAssertEqual(productionCommandEvents["resumed"] as? Bool, true)
      XCTAssertEqual(publicHost?.dashRecoveryAttempts, 2)
    }
    #if os(iOS)
    XCTAssertFalse(signalWriteFailed)
    #endif
    XCTAssertGreaterThanOrEqual(CMTimeGetSeconds(player.currentTime()), Double(programmeSeconds) - 0.5)
    publicHost?.close(); backend?.dispose(); player.pause(); player.replaceCurrentItem(with: nil)
    XCTAssertNil(player.currentItem)
  }

  private let origin = URL(string: "https://origin.test/root/movie.mpd?token=private")!
  private var mpd: Data { Data("""
    <MPD type="static" mediaPresentationDuration="PT4S"><Period><AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1000" codecs="avc1.64001f" width="320" height="180"><SegmentTemplate initialization="init.mp4" media="seg-$Number$.m4s" duration="2"/></Representation></AdaptationSet></Period></MPD>
    """.utf8) }
  private func prepare(_ config: URLSessionConfiguration, token: YlOpenCancellationToken = .init(), context: YlHlsCredentialContext = .init(), headers: [String: String] = [:], readTimeoutMs: Int = 500, retention: YlManagedBufferLedger.OpaqueHlsRetention? = nil) throws -> YlPreparedHlsAsset {
    try YlPreparedHlsAsset(originURL: origin, isDash: true, headers: headers, configuration: .init(map: ["connectTimeoutMs": 500, "readTimeoutMs": readTimeoutMs]), cancellationToken: token, credentialContext: context, sessionConfiguration: config, opaqueRetention: retention)
  }
  private func read(_ loader: YlHlsResourceLoader, _ url: URL) -> DashLoadingRequest {
    let request = DashLoadingRequest(url)
    XCTAssertTrue(loader.startLoading(request)); XCTAssertEqual(request.finishCount, 1)
    return request
  }
  private func child(_ master: Data) throws -> URL {
    try XCTUnwrap(String(data: master, encoding: .utf8)?.split(separator: "\n").last.flatMap { URL(string: String($0)) })
  }

  private var indexedMPD: Data { Data("""
    <MPD type="static" mediaPresentationDuration="PT4S"><Period><AdaptationSet mimeType="video/mp4"><SegmentBase indexRange="826-905"><Initialization range="0-825"/></SegmentBase><Representation id="v" bandwidth="1000" codecs="avc1.42c01e" width="320" height="180"><BaseURL>indexed.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>
    """.utf8) }
  private func indexBytes() throws -> Data {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "dash-sidx-v0", withExtension: "mp4"))
    return try Data(contentsOf: url).subdata(in: 826..<906)
  }
  func testIndexedPreflightRequestsExactRangeAndSnapshotReprojectsWithoutNetwork() throws {
    let manifest = indexedMPD, bytes = try indexBytes()
    let config = DashLoaderProtocol.configuration { request in
      if request.request.url!.path.hasSuffix(".mpd") { request.respond(manifest) }
      else { request.respond(bytes, status: 206, headers: ["Content-Range": "bytes 826-905/103362", "Content-Length": "80"]) }
    }
    let prepared = try prepare(config)
    let loader = try prepared.takeLoader(); defer { loader.cancelAll() }
    XCTAssertEqual(DashLoaderProtocol.captured.count, 2)
    XCTAssertEqual(DashLoaderProtocol.captured.last?.value(forHTTPHeaderField: "Range"), "bytes=826-905")
    let master = read(loader, try loader.encodedAssetURL())
    let playlist = String(decoding: read(loader, try child(master.received)).received, as: UTF8.self)
    XCTAssertTrue(playlist.contains("13625@906"))
    XCTAssertTrue(playlist.contains("826@0"))
    let snapshot = try XCTUnwrap(loader.dashSnapshot)
    let replacement = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      videoConstraints: .init(maxWidth: 320, maxHeight: 180, maxBitrate: 1000),
      headers: [:], configuration: .init(map: [:]), cancellationToken: .init(),
      dashSnapshot: snapshot, sessionConfiguration: config)
    let replacementLoader = try replacement.takeLoader(); defer { replacementLoader.cancelAll() }
    XCTAssertEqual(DashLoaderProtocol.captured.count, 2)
    XCTAssertEqual(replacementLoader.videoCatalog?.tracks(at: 0).count, 1)
  }
  func testIndexedPreflightRejectsWrongRangesWholeFilesAndTruncatedBodies() throws {
    let manifest = indexedMPD, bytes = try indexBytes()
    for (status, range, body) in [(200, "", bytes), (416, "", Data()),
      (206, "bytes 827-906/103362", bytes), (206, "bytes 826-904/103362", bytes),
      (206, "bytes 826-905/905", bytes), (206, "bytes 826-905/*", bytes),
      (206, "bytes 826-905/103362", Data(bytes.dropLast())),
      (206, "bytes 826-905/103362", bytes + Data([0]))] {
      let config = DashLoaderProtocol.configuration { request in
        if request.request.url!.path.hasSuffix(".mpd") { request.respond(manifest) }
        else { request.respond(body, status: status, headers: ["Content-Range": range]) }
      }
      XCTAssertThrowsError(try prepare(config)) { error in
        XCTAssertEqual((error as? NativePlayerError)?.code, status == 416 ? "network.http_status.416" : "network.range_invalid")
      }
    }
  }
  func testIndexedPreflightRejectsIndexOutsideResourceAndNonRandomAccess() throws {
    let manifest = indexedMPD, original = try indexBytes()
    for invalidSAP in [false, true] {
      var bytes = original
      if invalidSAP { bytes[40] = 0 } // first reference starts_with_SAP flag
      let config = DashLoaderProtocol.configuration { request in
        if request.request.url!.path.hasSuffix(".mpd") { request.respond(manifest) }
        else { request.respond(bytes, status: 206, headers: ["Content-Range": "bytes 826-905/\(invalidSAP ? 103362 : 1000)"]) }
      }
      XCTAssertThrowsError(try prepare(config)) { XCTAssertEqual(($0 as? NativePlayerError)?.code, "container.unsupported") }
    }
  }
  func testIndexedPreflightBudgetRejectsBeforeFetchingIndex() {
    let manifest = Data(String(decoding: indexedMPD, as: UTF8.self).replacingOccurrences(of: "826-905", with: "0-1048576").utf8)
    XCTAssertThrowsError(try prepare(DashLoaderProtocol.configuration { $0.respond(manifest) })) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "resource.exhausted")
    }
    XCTAssertEqual(DashLoaderProtocol.captured.count, 1)
  }
  func testIndexedPreflightCancellationStopsPendingIndexAndCannotPublish() throws {
    let manifest = indexedMPD, token = YlOpenCancellationToken()
    let requested = expectation(description: "index requested")
    let finished = expectation(description: "preflight cancelled")
    let config = DashLoaderProtocol.configuration { request in
      if request.request.url!.path.hasSuffix(".mpd") { request.respond(manifest) }
      else { requested.fulfill() }
    }
    DispatchQueue.global().async {
      do { _ = try self.prepare(config, token: token); XCTFail("cancelled preflight published") }
      catch { XCTAssertEqual((error as? NativePlayerError)?.code, "network.cancelled") }
      finished.fulfill()
    }
    wait(for: [requested], timeout: 3)
    token.cancel()
    wait(for: [finished], timeout: 3)
  }

  func testIndexedRangeAtInt64EndRejectsWithoutArithmeticTrap() {
    let manifest = Data(String(decoding: indexedMPD, as: UTF8.self)
      .replacingOccurrences(of: "826-905", with: "9223372036854775807-9223372036854775807").utf8)
    let config = DashLoaderProtocol.configuration { request in
      if request.request.url!.path.hasSuffix(".mpd") { request.respond(manifest) }
      else { request.respond(Data([0]), status: 206,
        headers: ["Content-Range": "bytes 9223372036854775807-9223372036854775807/9223372036854775807"]) }
    }
    XCTAssertThrowsError(try prepare(config)) { XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.range_invalid") }
  }

  func testIndexedRedirectCrossOriginReturnKeepsRangeAndStripsCredentials() throws {
    let bytes = try indexBytes(), manifest = indexedMPD
    let other = try DashHTTPServer(), server = try DashHTTPServer()
    defer { server.close(); other.close() }
    other.handler = { _ in (302, ["Location": server.url("/returned.mp4").absoluteString], Data()) }
    server.handler = { request in
      if request.path == "/movie.mpd" { return (200, [:], manifest) }
      if request.path == "/indexed.mp4" { return (302, ["Location": other.url("/hop").absoluteString], Data()) }
      return (206, ["Content-Range": "bytes 826-905/103362"], bytes)
    }
    let prepared = try YlPreparedHlsAsset(originURL: server.url("/movie.mpd"), isDash: true,
      headers: ["Authorization": "private", "Cookie": "private", "X-Client": "ordinary"],
      configuration: .init(map: [:]), cancellationToken: .init())
    defer { prepared.discard() }
    let returned = try XCTUnwrap(server.requests.first { $0.path == "/returned.mp4" })
    for request in [returned] + other.requests {
      XCTAssertNil(request.headers["authorization"]); XCTAssertNil(request.headers["cookie"])
      XCTAssertEqual(request.headers["range"], "bytes=826-905")
      XCTAssertEqual(request.headers["x-client"], "ordinary")
    }
    let master = read(prepared.loader, prepared.asset.url)
    let video = String(decoding: read(prepared.loader, try child(master.received)).received, as: UTF8.self)
    XCTAssertTrue(video.contains("credentialsStripped=1"))
  }
  func testIndexedRedirectLoopIsBounded() throws {
    let manifest = indexedMPD, server = try DashHTTPServer()
    defer { server.close() }
    server.handler = { request in
      request.path == "/movie.mpd" ? (200, [:], manifest)
        : (302, ["Location": server.url("/loop.mp4").absoluteString], Data())
    }
    XCTAssertThrowsError(try YlPreparedHlsAsset(originURL: server.url("/movie.mpd"), isDash: true,
      headers: [:], configuration: .init(map: ["maxRedirects": 2]), cancellationToken: .init())) {
      XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.redirect_limit")
    }
    XCTAssertLessThanOrEqual(server.requests.count, 4)
  }

  private var twoQualityMPD: Data {
    let high = "<Representation id=\"high\" bandwidth=\"2000\" codecs=\"avc1.64001f\" width=\"640\" height=\"360\"><SegmentTemplate initialization=\"high-init.mp4\" media=\"high-$Number$.m4s\" duration=\"2\"/></Representation>"
    return Data(String(decoding: mpd, as: UTF8.self).replacingOccurrences(of: "</AdaptationSet>", with: high + "</AdaptationSet>").utf8)
  }

  private var changingCatalogMPD: Data {
    let one = String(data: mpd, encoding: .utf8)!
      .replacingOccurrences(of: "mediaPresentationDuration=\"PT4S\"", with: "mediaPresentationDuration=\"PT8S\"")
      .replacingOccurrences(of: "<Period>", with: "<Period duration=\"PT4S\">")
    let low = one.components(separatedBy: "<Period")[1].components(separatedBy: "</Period>")[0]
    return Data(one.replacingOccurrences(of: "width=\"320\" height=\"180\"", with: "width=\"640\" height=\"360\"")
      .replacingOccurrences(of: "</MPD>", with: "<Period" + low + "</Period></MPD>").utf8)
  }

  @MainActor
  func testCatalogFollowsMeasuredProgramTimeAndPeriodicPublication() throws {
    let data = changingCatalogMPD
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    let player = DashCatalogClockPlayer()
    player.measuredTime = CMTime(value: 1_000_000, timescale: 1_000_000)
    var states: [YlNativeState] = [], trackEvents = 0
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, emit: {
        if case .state(let state) = $0.event { states.append(state) }
        if case .tracksChanged = $0.event { trackEvents += 1 }
      })
    defer { backend.dispose() }
    try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash), prepared: prepared, resume: false)
    try backend.activate()
    XCTAssertEqual(states.last?.videoTracks.map(\.id), ["dash-video-w640-h360-b1000"])
    XCTAssertEqual(states.last?.videoTracks.map(\.isSelected), [false])
    let loader = try XCTUnwrap((player.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    let master = read(loader, try loader.encodedAssetURL())
    _ = read(loader, try child(master.received)) // Reading all later segments cannot advance the catalog.
    backend.emitState()
    XCTAssertEqual(states.last?.videoTracks.first?.width, 640)
    let count = trackEvents
    player.tick?(.zero); player.tick?(.zero)
    XCTAssertEqual(trackEvents, count)
    player.measuredTime = CMTime(value: 5_000_000, timescale: 1_000_000)
    player.tick?(.zero)
    XCTAssertEqual(states.last?.positionMs, 5000)
    XCTAssertEqual(states.last?.videoTracks.map(\.id), ["dash-video-w320-h180-b1000"])
    XCTAssertEqual(trackEvents, count + 1)
  }

  func testCatalogLoaderSnapshotSurvivesCancellationWhilePrivateSnapshotClears() throws {
    let data = changingCatalogMPD
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    let loader = try prepared.takeLoader()
    let snapshot = try XCTUnwrap(loader.videoCatalog)
    XCTAssertEqual(snapshot.tracks(at: 0).first?.width, 640)
    XCTAssertEqual(snapshot.tracks(at: 4_000_000).first?.width, 320)
    loader.cancelAll()
    XCTAssertNil(loader.videoCatalog)
    XCTAssertEqual(snapshot.tracks(at: 4_000_000).first?.width, 320)
  }

  @MainActor
  func testCatalogSeekUsesActualLandingAndRetiredCompletionCannotPublish() async throws {
    let data = changingCatalogMPD
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    let player = DashCatalogClockPlayer()
    player.measuredTime = CMTime(value: 1, timescale: 1)
    var states: [YlNativeState] = []
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player,
      emit: { if case .state(let state) = $0.event { states.append(state) } })
    defer { backend.dispose() }
    try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash), prepared: prepared, resume: false)
    try backend.activate(); try backend.pause()
    try backend.seek(toMs: 5000)
    backend.emitState()
    XCTAssertEqual(states.last?.positionMs, 1000)
    XCTAssertEqual(states.last?.videoTracks.first?.width, 640)
    player.measuredTime = CMTime(value: 5, timescale: 1)
    player.seekCompletion?(true)
    for _ in 0..<12 { await Task.yield() }
    XCTAssertEqual(states.last?.positionMs, 5000)
    XCTAssertEqual(states.last?.videoTracks.first?.width, 320)
    try backend.seek(toMs: 1000)
    let retired = player.seekCompletion
    backend.stop()
    XCTAssertEqual(states.last?.videoTracks.count, 0)
    retired?(true)
    for _ in 0..<12 { await Task.yield() }
    XCTAssertEqual(states.last?.videoTracks.count, 0)
    XCTAssertEqual(states.last?.status, "idle")
  }

  @MainActor
  func testCatalogMetadataIsolationOrdinarySourceAndSavedPositionRestoration() throws {
    let data = changingCatalogMPD
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    let player = DashCatalogClockPlayer()
    player.measuredTime = CMTime(value: 5, timescale: 1)
    var states: [YlNativeState] = []
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player,
      emit: { if case .state(let state) = $0.event { states.append(state) } })
    defer { backend.dispose() }
    let source = YlAppleSourceDescriptor(uri: origin.absoluteString, kind: .network, formatHint: .dash)
    try backend.stagePreparedHls(source: source, prepared: prepared, resume: false)
    try backend.activate()
    let retiredItem = try XCTUnwrap(player.currentItem)
    let metadata = [YlNativeTrack(id: "video-0", kind: .video, width: 999, isSelected: true)]
    backend.applyMetadataVideoTracks(metadata, for: retiredItem); backend.emitState()
    XCTAssertEqual(states.last?.videoTracks.first?.id, "dash-video-w320-h180-b1000")
    backend.deactivate()
    player.measuredTime = .invalid
    backend.emitState()
    XCTAssertEqual(states.last?.positionMs, 5000)
    XCTAssertEqual(states.last?.videoTracks.first?.width, 320)
    let restored = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    try backend.stagePreparedHls(source: source, prepared: restored, resume: true)
    try backend.activate()
    XCTAssertEqual(states.last?.videoTracks.first?.width, 320)
    XCTAssertEqual(states.last?.positionMs, 5000)
    try backend.open(.init(uri: "https://origin.test/new.mp4", kind: .network, formatHint: .mp4))
    backend.applyMetadataVideoTracks(metadata, for: retiredItem); backend.emitState()
    XCTAssertEqual(states.last?.videoTracks.count, 0)
    backend.applyMetadataVideoTracks(metadata, for: try XCTUnwrap(player.currentItem)); backend.emitState()
    XCTAssertEqual(states.last?.videoTracks.first?.id, "video-0")
    XCTAssertEqual(states.last?.videoTracks.first?.isSelected, true)
  }

  @MainActor
  func testCatalogBackendSubMillisecondBoundaryAndInvalidClockAreSafe() throws {
    let data = Data(String(data: changingCatalogMPD, encoding: .utf8)!
      .replacingOccurrences(of: "PT8S", with: "PT8.001S")
      .replacingOccurrences(of: "PT4S", with: "PT4.000500S")
      .replacingOccurrences(of: "duration=\"2\"", with: "timescale=\"1000000\" duration=\"4000500\"").utf8)
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    let player = DashCatalogClockPlayer()
    player.measuredTime = CMTime(value: 4_000_499, timescale: 1_000_000)
    var states: [YlNativeState] = []
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player,
      emit: { if case .state(let state) = $0.event { states.append(state) } })
    defer { backend.dispose() }
    try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash), prepared: prepared, resume: false)
    try backend.activate()
    XCTAssertEqual(states.last?.positionMs, 4000)
    XCTAssertEqual(states.last?.videoTracks.first?.width, 640)
    player.measuredTime = CMTime(value: 4_000_500, timescale: 1_000_000)
    player.tick?(.zero)
    XCTAssertEqual(states.last?.positionMs, 4000)
    XCTAssertEqual(states.last?.videoTracks.first?.width, 320)
    for time in [CMTime.invalid, .indefinite, .positiveInfinity, CMTime(value: -1, timescale: 1)] {
      player.measuredTime = time; backend.emitState()
      XCTAssertEqual(states.last?.positionMs, 0)
      XCTAssertEqual(states.last?.videoTracks.first?.width, 640)
    }
    player.measuredTime = CMTime(value: Int64.max, timescale: 1)
    backend.emitState() // Conversion overflow must never trap.
    XCTAssertGreaterThanOrEqual(states.last?.positionMs ?? -1, 0)
    player.measuredTime = CMTime(value: 4_000_500, timescale: 1_000_000)
    backend.deactivate(); backend.emitState()
    XCTAssertEqual(states.last?.positionMs, 4000)
    XCTAssertEqual(states.last?.videoTracks.first?.width, 320, "Saving time must retain the fractional-ms boundary")
  }

  @MainActor
  func testCatalogRetainedReplacementRestoreSeeksExactFractionalBoundary() throws {
    try assertCatalogRestoreLanding(retained: true)
  }

  @MainActor
  func testCatalogStagedLoaderRestoreSeeksExactFractionalBoundary() throws {
    try assertCatalogRestoreLanding(retained: false)
  }

  @MainActor
  private func assertCatalogRestoreLanding(retained: Bool) throws {
    let xml = String(data: mpd, encoding: .utf8)!
    let high = xml.replacingOccurrences(of: "mediaPresentationDuration=\"PT4S\"", with: "mediaPresentationDuration=\"PT8.001S\"")
      .replacingOccurrences(of: "<Period>", with: "<Period duration=\"PT6.500500S\">")
      .replacingOccurrences(of: "width=\"320\" height=\"180\"", with: "width=\"640\" height=\"360\"")
      .replacingOccurrences(of: "duration=\"2\"", with: "timescale=\"1000000\" duration=\"6500500\"")
    let low = xml.components(separatedBy: "<Period>")[1].components(separatedBy: "</Period>")[0]
      .replacingOccurrences(of: "duration=\"2\"", with: "timescale=\"1000000\" duration=\"1500500\"")
    let data = Data(high.replacingOccurrences(of: "</MPD>", with: "<Period duration=\"PT1.500500S\">" + low + "</Period></MPD>").utf8)
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    let player = DashCatalogClockPlayer()
    let boundary = CMTime(value: 6_500_500, timescale: 1_000_000)
    player.measuredTime = boundary
    player.timelineDuration = CMTime(value: 8_001_000, timescale: 1_000_000)
    player.timelineRanges = [NSValue(timeRange: CMTimeRange(start: .zero, duration: player.timelineDuration!))]
    var states: [YlNativeState] = []
    let backend = YlAvPlayerBackend(playerId: 99,
      // The iOS compatibility route retains the installed asset for rollback.
      services: .init(platform: retained ? .ios : .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player,
      emit: { if case .state(let state) = $0.event { states.append(state) } })
    defer { backend.dispose() }
    let source = YlAppleSourceDescriptor(uri: origin.absoluteString, kind: .network, formatHint: .dash)
    try backend.stagePreparedHls(source: source, prepared: prepared, resume: false)
    try backend.activate()
    let originalAsset = player.currentItem?.asset
    XCTAssertEqual(player.currentItem?.duration.isNumeric, true)
    XCTAssertEqual(player.currentItem?.seekableTimeRanges.count, 1)
    XCTAssertEqual(states.last?.videoTracks.first?.width, 320)
    if retained { backend.quiesceForReplacement() } else { backend.deactivate() }
    XCTAssertEqual(states.last?.positionMs, 6500)
    XCTAssertEqual(states.last?.videoTracks.first?.width, 320)
    if !retained {
      let restored = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
      try backend.stagePreparedHls(source: source, prepared: restored, resume: true)
    }
    player.measuredTime = .invalid
    player.requestedSeek = nil
    player.landOnSeek = true
    try backend.activate()
    XCTAssertEqual(player.currentItem?.asset === originalAsset, retained)
    let requested = try XCTUnwrap(player.requestedSeek)
    XCTAssertEqual(CMTimeCompare(requested, boundary), 0, "Restoration must not cross back into the previous Period")
    XCTAssertEqual(CMTimeCompare(player.measuredTime, boundary), 0)
    backend.emitState()
    XCTAssertEqual(states.last?.positionMs, 6500, "Public timeline remains milliseconds")
    XCTAssertEqual(states.last?.videoTracks.first?.id, "dash-video-w320-h180-b1000")
    XCTAssertEqual(states.last?.videoTracks.first?.isSelected, false)
  }

  @MainActor
  func testLiveEdgeRestorationPreservesExplicitAndIndefiniteLiveBehavior() throws {
    for explicitLive in [false, true] {
      let player = DashCatalogClockPlayer()
      player.measuredTime = CMTime(value: 6_500_500, timescale: 1_000_000)
      let end = CMTime(value: 8_001_000, timescale: 1_000_000)
      player.timelineDuration = explicitLive ? end : .indefinite
      player.timelineRanges = [NSValue(timeRange: CMTimeRange(start: .zero, duration: end))]
      let backend = YlAvPlayerBackend(playerId: 99,
        services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, emit: { _ in })
      defer { backend.dispose() }
      try backend.open(.init(uri: "https://origin.test/live.m3u8", kind: .network, formatHint: .hls,
        intent: explicitLive ? .live : .automatic))
      backend.deactivate()
      player.measuredTime = .invalid
      player.requestedSeek = nil
      player.landOnSeek = true
      try backend.activate()
      XCTAssertNil(player.requestedSeek, "Live near-edge restore must retain its deferred edge seek")
      try backend.seekToLiveEdge()
      XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), end), 0)
      XCTAssertEqual(CMTimeCompare(player.measuredTime, end), 0)
    }
  }

  @MainActor
  func testLoadCapsDropActualOversizedBufferBeforeDirectReturnAndPublication() async throws {
    let data = mpd
    let prepared = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      videoConstraints: .init(maxWidth: 320, maxHeight: 180, maxBitrate: nil), headers: [:],
      configuration: .init(map: [:]), cancellationToken: .init(),
      sessionConfiguration: DashLoaderProtocol.configuration { $0.respond(data) })
    let output = AppleTestTexture()
    let pixels = DashPixelOutput(width: 640, height: 360)
    var tick: (() -> Void)?
    var failures: [NativePlayerError] = [], firstFrames = 0
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: output,
        makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), makeVideoOutput: { _ in pixels }, emit: {
        if case .failure(let error) = $0.event { failures.append(error); XCTAssertTrue(Thread.isMainThread) }
        if case .firstFrame = $0.event { firstFrames += 1 }
      })
    defer { backend.dispose() }
    let source = YlAppleSourceDescriptor(uri: origin.absoluteString, kind: .network, formatHint: .dash)
    try backend.stagePreparedHls(source: source, prepared: prepared, resume: false)
    try backend.activate()
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
    tick?()
    for _ in 0..<12 { await Task.yield() }
    XCTAssertEqual(output.frames.count, 0)
    XCTAssertEqual(firstFrames, 0)
    XCTAssertEqual(failures.map(\.code), ["decoder.quality_constraint_unsupported"])
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
  }

  @MainActor func testConfirmedCapsFrameFailureCannotBecomeSilentAfterSeek() async throws {
    let player = DashCatalogClockPlayer(), pixels = DashPixelOutput(width: 640, height: 360)
    var failures: [String] = []
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, makeVideoOutput: { _ in pixels }, emit: {
        if case .failure(let error) = $0.event { failures.append(error.code) }
      })
    defer { backend.dispose() }
    let data = mpd
    let prepared = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      videoConstraints: .init(maxWidth: 320, maxHeight: 180, maxBitrate: nil), headers: [:],
      configuration: .init(map: [:]), cancellationToken: .init(), sessionConfiguration: DashLoaderProtocol.configuration { $0.respond(data) })
    try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash), prepared: prepared, resume: false)
    try backend.activate()
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue(), "Current caps violation is synchronously rejected and latched")
    try backend.seek(toMs: 1000)
    try XCTUnwrap(player.seekCompletion)(true)
    let drained = expectation(description: "confirmed terminal delivered")
    DispatchQueue.main.async { drained.fulfill() }; await fulfillment(of: [drained], timeout: 1)
    XCTAssertEqual(failures, ["decoder.quality_constraint_unsupported"], "Seek must not suppress a confirmed terminal latch and silently block output")
  }

  @MainActor func testSeekRevisionRejectsInFlightRasterCopyAndStaleFixedFailure() async throws {
    for fixed in [false, true] {
      let player = DashCatalogClockPlayer(), pixels = DashPixelOutput(width: fixed ? 640 : 320, height: fixed ? 360 : 180)
      var failures: [String] = []
      let backend = YlAvPlayerBackend(playerId: 99,
        services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, makeVideoOutput: { _ in pixels }, emit: {
          if case .failure(let error) = $0.event { failures.append(error.code) }
        })
      defer { backend.dispose() }
      let data = mpd
      try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash),
        prepared: prepare(DashLoaderProtocol.configuration { $0.respond(data) }), resume: false)
      try backend.activate()
      if fixed {
        let track = try XCTUnwrap(backend.confirmedVideoTracks.first { $0.width == 320 })
        backend.acceptVideoSelection(.init(fixedTrackId: track.id, reason: "user"))
        // Commit a fixed landing before the background copy snapshots FramePolicy.
        try backend.seek(toMs: 0); try XCTUnwrap(player.seekCompletion)(true)
        let fixedReady = expectation(description: "fixed policy ready")
        DispatchQueue.main.async { fixedReady.fulfill() }; await fulfillment(of: [fixedReady], timeout: 1)
        XCTAssertEqual(backend.videoSelection.fixedTrackId, track.id)
      }
      let entered = expectation(description: "raster copy entered"), released = DispatchSemaphore(value: 0)
      defer { released.signal() }
      pixels.beforeCopy = { entered.fulfill(); XCTAssertEqual(released.wait(timeout: .now()+3), .success) }
      let copy = Task.detached { backend.copyPixelBuffer()?.takeRetainedValue() != nil }
      await fulfillment(of: [entered], timeout: 1)
      try backend.seek(toMs: 1000)
      player.measuredTime = CMTime(seconds: 1, preferredTimescale: 1000)
      try XCTUnwrap(player.seekCompletion)(true)
      let landed = expectation(description: "seek landed")
      DispatchQueue.main.async { landed.fulfill() }; await fulfillment(of: [landed], timeout: 1)
      released.signal()
      let copied = await copy.value
      XCTAssertFalse(copied, "Old raster copy cannot cross a complete seek transition")
      let drained = expectation(description: "old errors drained")
      DispatchQueue.main.async { drained.fulfill() }; await fulfillment(of: [drained], timeout: 1)
      XCTAssertFalse(failures.contains("decoder.quality_constraint_unsupported"), "A stale fixed buffer cannot terminate the new landing")
    }
  }

  @MainActor func testAutomaticUserSeekBlocksOldFramesUntilLatestLanding() async throws {
    let player = DashCatalogClockPlayer(), output = AppleTestTexture(), pixels = DashPixelOutput(width: 320, height: 180)
    var tick: (() -> Void)?
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, makeVideoOutput: { _ in pixels }, emit: { _ in })
    defer { backend.dispose() }
    let data = mpd
    try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash),
      prepared: prepare(DashLoaderProtocol.configuration { $0.respond(data) }), resume: false)
    try backend.activate(); try backend.play(); tick?()
    let count = output.frames.count
    XCTAssertGreaterThan(count, 0)
    try backend.seek(toMs: 1000)
    let first = try XCTUnwrap(player.seekCompletion)
    tick?(); XCTAssertEqual(output.frames.count, count, "Automatic selection cannot publish the old timeline while seek is pending")
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
    try backend.seek(toMs: 2000)
    let latest = try XCTUnwrap(player.seekCompletion)
    first(true)
    let staleDrained = expectation(description: "stale callback drained")
    DispatchQueue.main.async { staleDrained.fulfill() }; await fulfillment(of: [staleDrained], timeout: 1)
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue(), "An older seek callback cannot reopen publication")
    player.measuredTime = CMTime(seconds: 2, preferredTimescale: 1000); pixels.measuredItemTime = player.measuredTime
    latest(true)
    let landed = expectation(description: "latest callback drained")
    DispatchQueue.main.async { landed.fulfill() }; await fulfillment(of: [landed], timeout: 1)
    tick?(); XCTAssertEqual(output.frames.count, count + 1)
  }

  @MainActor
  func testSameSessionAutomaticReplacementRetainsFrameOnlyWithoutChangedIntent() async throws {
    // A same-URI new load is not the same session. A seek or quality change
    // must not keep a frame from the old timeline/policy visible.
    for mode in ["same", "new-session", "uri", "manifest", "caps", "fixed", "seek", "pause"] {
      let player = DashCatalogClockPlayer(), output = AppleTestTexture()
      let pixels = DashPixelOutput(width: 320, height: 180)
      var tick: (() -> Void)?
      let backend = YlAvPlayerBackend(playerId: 99,
        services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), player: player,
        makeVideoOutput: { _ in pixels }, emit: { _ in })
      defer { backend.dispose() }
      let source = YlAppleSourceDescriptor(uri: origin.absoluteString, kind: .network, formatHint: .dash)
      let data = mpd
      let original = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
      let snapshot = try XCTUnwrap(original.loader.dashSnapshot)
      try backend.stagePreparedHls(source: source, prepared: original, resume: false)
      try backend.activate(); try backend.play()
      tick?()
      XCTAssertFalse(output.frames.isEmpty, mode)
      player.measuredTime = CMTime(value: 1_000_500, timescale: 1_000_000)
      var replacementSource = source
      if mode == "new-session" { replacementSource.managedRequestIntent = .init() }
      if mode == "uri" { replacementSource.uri = "https://origin.test/other.mpd" }
      if mode == "seek" { try backend.seek(toMs: 2_000) }
      if mode == "pause" { try backend.pause() }
      let changed = YlDashManifestSnapshot(data: data + Data([10]), effectiveURL: snapshot.effectiveURL,
        credentialsStripped: snapshot.credentialsStripped)
      let replacement = try YlPreparedHlsAsset(originURL: origin, isDash: true,
        videoConstraints: mode == "caps" ? .init(maxWidth: 320, maxHeight: 180, maxBitrate: nil) : .unconstrained,
        fixedTrackId: mode == "fixed" ? "dash-video-w320-h180-b1000" : nil,
        headers: [:], configuration: .init(map: [:]), cancellationToken: .init(),
        dashSnapshot: mode == "manifest" ? changed : snapshot)
      let clears = output.clears, frames = output.frames.count, oldItem = player.currentItem
      try backend.replaceActiveDash(source: replacementSource, prepared: replacement,
        selection: mode == "fixed" ? .init(fixedTrackId: "dash-video-w320-h180-b1000", reason: "user") : nil)
      XCTAssertFalse(player.currentItem === oldItem, mode)
      XCTAssertEqual(output.clears - clears, mode == "same" ? 0 : 1, mode)
      tick?()
      XCTAssertEqual(output.frames.count, frames, "Retaining a frame cannot publish before seek landing: \(mode)")
      backend.stop()
      XCTAssertGreaterThan(output.clears, clears, "Stop always clears retained output: \(mode)")
    }
  }

  @MainActor
  func testRuntimeMetadataBeforeHeldResumeKeepsAudioSelectionRotationAndReadiness() async throws {
    let media = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264_aac", withExtension: "mp4"))
    let data = mpd
    let player = DashCatalogClockPlayer(), output = AppleTestTexture()
    let pixels = DashPixelOutput(width: 320, height: 180)
    var states: [YlNativeState] = []
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player,
      makePlayerItem: { _ in AVPlayerItem(url: media) }, makeVideoOutput: { _ in pixels },
      emit: { if case .state(let state) = $0.event { states.append(state) } })
    defer { backend.dispose() }
    let source = YlAppleSourceDescriptor(uri: origin.absoluteString, kind: .network, formatHint: .dash)
    let original = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    let snapshot = try XCTUnwrap(original.loader.dashSnapshot)
    try backend.stagePreparedHls(source: source, prepared: original, resume: false)
    try backend.activate()
    try await AppleHostCharacterizations.waitFor { states.last?.audioTracks.isEmpty == false }
    try backend.selectAudioTrack("audio-0")
    XCTAssertEqual(states.last?.audioTracks.first?.isSelected, true)
    player.measuredTime = CMTime(value: 1_000_500, timescale: 1_000_000)
    let replacement = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      videoConstraints: .init(maxWidth: 640, maxHeight: 640, maxBitrate: nil), headers: [:],
      configuration: .init(map: [:]), cancellationToken: .init(), dashSnapshot: snapshot)
    try backend.replaceActiveDash(source: source, prepared: replacement)
    let heldSeek = try XCTUnwrap(player.seekCompletion)
    // The actual AVAsset reader must finish while the resume seek stays held.
    try await AppleHostCharacterizations.waitFor { states.last?.status == "ready" }
    try await AppleHostCharacterizations.waitFor { states.last?.audioTracks.isEmpty == false }
    XCTAssertEqual(states.last?.audioTracks.first?.id, "audio-0")
    XCTAssertEqual(states.last?.audioTracks.first?.isSelected, true)
    XCTAssertNotNil(states.last?.geometry)
    let rotated = YlVideoGeometryResolver.resolve(encodedSize: .init(width: 320, height: 180),
      cleanAperture: nil, pixelAspectRatio: 1, rotationDegrees: 90)
    XCTAssertTrue(backend.applyMetadataGeometry(rotated, hasVideoTracks: true))
    backend.emitState()
    XCTAssertEqual(states.last?.geometry?.rotationDegrees, 90)
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue(), "Metadata does not open the pending-seek frame gate")
    player.measuredTime = CMTime(value: 1_001_000, timescale: 1_000_000)
    heldSeek(true)
    for _ in 0..<12 { await Task.yield() }
    backend.emitState()
    XCTAssertEqual(states.last?.status, "ready")
    XCTAssertEqual(states.last?.audioTracks.first?.isSelected, true)
    XCTAssertEqual(states.last?.geometry?.rotationDegrees, 90)
    XCTAssertNotNil(backend.copyPixelBuffer()?.takeRetainedValue())
  }

  func testRuntimeSnapshotKeepsOriginalEffectiveURLAndClearsCancelledLoaderOwnership() throws {
    let data = mpd
    let effective = URL(string: "https://origin.test/redirected/movie.mpd")!
    let context = YlHlsCredentialContext()
    context.strip(origin.absoluteString)
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data, finalURL: effective) }, context: context)
    let snapshot = try XCTUnwrap(prepared.loader.dashSnapshot)
    XCTAssertEqual(snapshot.data, data)
    XCTAssertEqual(snapshot.effectiveURL, effective)
    XCTAssertTrue(snapshot.credentialsStripped)
    prepared.discard()
    XCTAssertNil(prepared.loader.dashSnapshot)
    let token = YlOpenCancellationToken()
    let restored = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      videoConstraints: .init(maxWidth: 640, maxHeight: nil, maxBitrate: nil), headers: ["Authorization": "private"],
      configuration: .init(map: [:]), cancellationToken: token, dashSnapshot: snapshot,
      credentialContext: context, sessionConfiguration: DashLoaderProtocol.configuration { _ in XCTFail("Snapshot recompilation cannot refetch") })
    XCTAssertEqual(restored.loader.dashSnapshot?.effectiveURL, effective)
    XCTAssertEqual(restored.loader.videoCatalog?.tracks(at: 0).count, 1)
    XCTAssertTrue(context.isStripped("https://origin.test/redirected/init.mp4"))
    XCTAssertEqual(DashLoaderProtocol.captured.count, 0)
    token.cancel()
    XCTAssertNil(restored.loader.dashSnapshot)
    XCTAssertNil(restored.loader.videoCatalog)
    XCTAssertEqual(snapshot.data, data)
  }

  @MainActor
  func testRuntimeCapsCommitSamplesLatestExactTimeAndPauseAndFreezesPendingSeek() async throws {
    let entered = expectation(description: "caps preparation entered")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    let server = try DashHTTPServer(); defer { server.close() }
    let data = changingCatalogMPD
    server.handler = { _ in (200, [:], data) }
    let player = DashCatalogClockPlayer(), output = AppleTestTexture()
    var states: [YlNativeState] = []
    let coordinator = YlAppleSessionCoordinator(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), textureOwner: .init(output: output, onFrame: { _ in }),
      avPlayer: player, beforeDashCapsPreparation: { token in
        entered.fulfill(); _ = release.wait(timeout: .now() + 5); try token.throwIfCancelled()
      }, emit: { _, callback in if case .state(let state) = callback.event { states.append(state) } })
    defer { coordinator.dispose() }
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      coordinator.load(.init(source: .init(uri: server.url("/movie.mpd").absoluteString, kind: .network, formatHint: .dash)),
        identity: .init(sessionId: "stable", loadRequestId: "load"), willCommit: { _ in }, didCommit: {}, didRollback: {},
        completion: { c.resume(with: $0.mapError { $0 as Error }) })
    }
    let old = player.currentItem
    var result: Result<Void, NativePlayerError>?
    coordinator.execute(.constraints(.init(maxWidth: 640, maxHeight: nil, maxBitrate: nil))) { result = $0 }
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertNil(result); XCTAssertTrue(player.currentItem === old)
    player.landOnSeek = true
    try coordinator.executeSynchronous(.seek(4_000))
    player.seekCompletion?(true)
    for _ in 0..<8 { await Task.yield() }
    player.measuredTime = CMTime(value: 4_000_500, timescale: 1_000_000)
    try coordinator.executeSynchronous(.pause)
    try coordinator.executeSynchronous(.speed(1.5))
    try coordinator.executeSynchronous(.volume(0.25))
    player.resetClockOnReplacement = true; player.landOnSeek = false
    release.signal()
    try await AppleHostCharacterizations.waitFor { result != nil }
    try result?.get()
    XCTAssertFalse(player.currentItem === old)
    XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), CMTime(value: 4_000_500, timescale: 1_000_000)), 0)
    XCTAssertFalse(coordinator.currentPlaybackIntent)
    XCTAssertEqual(player.volume, 0.25)
    XCTAssertEqual(coordinator.acceptedVideoConstraints.maxWidth, 640)
    XCTAssertEqual(states.last?.positionMs, 4_000)
    XCTAssertEqual(states.last?.videoTracks.first?.id, "dash-video-w320-h180-b1000")
    let completion = player.seekCompletion
    player.measuredTime = CMTime(value: 4_001_000, timescale: 1_000_000)
    completion?(true)
    for _ in 0..<8 { await Task.yield() }
    coordinator.emitState()
    XCTAssertEqual(states.last?.positionMs, 4_001)
  }

  @MainActor
  func testFixedSelectionPreparationReconcilesLatestPeriodAndTransportIntent() async throws {
    let entered = expectation(description: "caps preparation entered")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    let server = try DashHTTPServer(); defer { server.close() }
    let data = changingCatalogMPD
    server.handler = { _ in (200, [:], data) }
    let player = DashCatalogClockPlayer(), output = AppleTestTexture()
    var states: [YlNativeState] = []
    let coordinator = YlAppleSessionCoordinator(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), textureOwner: .init(output: output, onFrame: { _ in }),
      avPlayer: player, beforeDashCapsPreparation: { token in
        entered.fulfill(); _ = release.wait(timeout: .now() + 5); try token.throwIfCancelled()
      }, emit: { _, callback in if case .state(let state) = callback.event { states.append(state) } })
    defer { coordinator.dispose() }
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      coordinator.load(.init(source: .init(uri: server.url("/movie.mpd").absoluteString, kind: .network, formatHint: .dash)),
        identity: .init(sessionId: "stable", loadRequestId: "load"), willCommit: { _ in }, didCommit: {}, didRollback: {},
        completion: { c.resume(with: $0.mapError { $0 as Error }) })
    }
    let old = player.currentItem
    var result: Result<Void, NativePlayerError>?
    coordinator.execute(.videoTrack("dash-video-w640-h360-b1000")) { result = $0 }
    await fulfillment(of: [entered], timeout: 2)
    XCTAssertNil(result); XCTAssertTrue(player.currentItem === old)
    player.landOnSeek = true
    try coordinator.executeSynchronous(.seek(4_000))
    player.seekCompletion?(true)
    for _ in 0..<8 { await Task.yield() }
    player.measuredTime = CMTime(value: 4_000_500, timescale: 1_000_000)
    try coordinator.executeSynchronous(.pause)
    try coordinator.executeSynchronous(.speed(1.5))
    try coordinator.executeSynchronous(.volume(0.25))
    player.resetClockOnReplacement = true; player.landOnSeek = false
    release.signal()
    try await AppleHostCharacterizations.waitFor { result != nil }
    try result?.get()
    XCTAssertFalse(player.currentItem === old)
    XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), CMTime(value: 4_000_500, timescale: 1_000_000)), 0)
    XCTAssertFalse(coordinator.currentPlaybackIntent)
    XCTAssertEqual(player.volume, 0.25)
    XCTAssertNil(coordinator.acceptedVideoConstraints.maxWidth)
    XCTAssertEqual(states.last?.videoSelection.reason, "trackUnavailable")
    XCTAssertNil(states.last?.videoSelection.fixedTrackId)
    XCTAssertEqual(states.last?.positionMs, 4_000)
    XCTAssertEqual(states.last?.videoTracks.first?.id, "dash-video-w320-h180-b1000")
    let completion = player.seekCompletion
    player.measuredTime = CMTime(value: 4_001_000, timescale: 1_000_000)
    completion?(true)
    for _ in 0..<8 { await Task.yield() }
    coordinator.emitState()
    XCTAssertEqual(states.last?.positionMs, 4_001)
  }

  @MainActor
  func testRuntimeCapsTransfersLatestUnlandedSeekAndRejectsRetiredCompletions() async throws {
    for targetMs: Int64 in [5_000, 0] {
      let entered = expectation(description: "caps held for unresolved seek")
      let release = DispatchSemaphore(value: 0); defer { release.signal() }
      let server = try DashHTTPServer(); defer { server.close() }
      let data = changingCatalogMPD; server.handler = { _ in (200, [:], data) }
      let player = DashCatalogClockPlayer(), output = AppleTestTexture()
      var states: [YlNativeState] = [], preparations = 0
      let coordinator = YlAppleSessionCoordinator(playerId: 99,
        services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), textureOwner: .init(output: output, onFrame: { _ in }),
        avPlayer: player, beforeDashCapsPreparation: { token in
          preparations += 1
          if preparations == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
          try token.throwIfCancelled()
        }, emit: { _, callback in if case .state(let state) = callback.event { states.append(state) } })
      defer { coordinator.dispose() }
      func load(_ id: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
          coordinator.load(.init(source: .init(uri: server.url("/movie.mpd").absoluteString, kind: .network, formatHint: .dash)),
            identity: .init(sessionId: id, loadRequestId: id), willCommit: { _ in }, didCommit: {}, didRollback: {},
            completion: { c.resume(with: $0.mapError { $0 as Error }) })
        }
      }
      try await load("accepted")
      player.measuredTime = CMTime(value: 1_000_500, timescale: 1_000_000)
      let oldItem = player.currentItem
      var result: Result<Void, NativePlayerError>?
      coordinator.execute(.constraints(.init(maxWidth: 640, maxHeight: nil, maxBitrate: nil))) { result = $0 }
      await fulfillment(of: [entered], timeout: 2)
      XCTAssertFalse(player.landOnSeek)
      try coordinator.executeSynchronous(.seek(2_000))
      let superseded = try XCTUnwrap(player.seekCompletion)
      try coordinator.executeSynchronous(.seek(targetMs))
      let retired = try XCTUnwrap(player.seekCompletion)
      superseded(false)
      for _ in 0..<8 { await Task.yield() }
      coordinator.emitState()
      XCTAssertEqual(states.last?.positionMs, 1_000, "Ordinary pending seek must still publish measured time")
      XCTAssertTrue(player.currentItem === oldItem)
      player.resetClockOnReplacement = true
      release.signal()
      try await AppleHostCharacterizations.waitFor { result != nil }
      try result?.get()
      XCTAssertFalse(player.currentItem === oldItem)
      XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), CMTime(value: targetMs, timescale: 1_000)), 0)
      let transferred = try XCTUnwrap(player.seekCompletion)
      retired(true)
      for _ in 0..<8 { await Task.yield() }
      coordinator.emitState()
      XCTAssertEqual(states.last?.positionMs, targetMs, "Retired item completion cannot clear the transferred anchor")
      try coordinator.executeSynchronous(.seek(6_000))
      let latest = try XCTUnwrap(player.seekCompletion)
      transferred(false)
      for _ in 0..<8 { await Task.yield() }
      coordinator.emitState()
      XCTAssertEqual(states.last?.positionMs, 6_000, "Superseded replacement seek cannot clear the newest anchor")
      player.measuredTime = CMTime(value: 6_001_500, timescale: 1_000_000)
      latest(true)
      for _ in 0..<8 { await Task.yield() }
      result = nil
      coordinator.execute(.constraints(.unconstrained)) { result = $0 }
      try await AppleHostCharacterizations.waitFor { result != nil }
      try result?.get()
      XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), CMTime(value: 6_001_500, timescale: 1_000_000)), 0,
        "Completed user seek no longer overrides the measured fractional clock")
      try coordinator.executeSynchronous(.seek(7_000))
      let stoppedSeek = try XCTUnwrap(player.seekCompletion)
      coordinator.stop()
      try await load("after-stop")
      stoppedSeek(true)
      for _ in 0..<8 { await Task.yield() }
      player.measuredTime = CMTime(value: 2_001_500, timescale: 1_000_000)
      result = nil
      coordinator.execute(.constraints(.init(maxWidth: 640, maxHeight: nil, maxBitrate: nil))) { result = $0 }
      try await AppleHostCharacterizations.waitFor { result != nil }
      try result?.get()
      XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), CMTime(value: 2_001_500, timescale: 1_000_000)), 0,
        "Stop and new Load cannot retain a retired user seek")
    }
  }

  @MainActor
  func testFixedSelectionTransfersLatestUnlandedSeekAndRejectsRetiredCompletions() async throws {
    for targetMs: Int64 in [5_000, 0] {
      let entered = expectation(description: "caps held for unresolved seek")
      let release = DispatchSemaphore(value: 0); defer { release.signal() }
      let server = try DashHTTPServer(); defer { server.close() }
      let data = changingCatalogMPD; server.handler = { _ in (200, [:], data) }
      let player = DashCatalogClockPlayer(), output = AppleTestTexture()
      var states: [YlNativeState] = [], preparations = 0
      let coordinator = YlAppleSessionCoordinator(playerId: 99,
        services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), textureOwner: .init(output: output, onFrame: { _ in }),
        avPlayer: player, beforeDashCapsPreparation: { token in
          preparations += 1
          if preparations == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
          try token.throwIfCancelled()
        }, emit: { _, callback in if case .state(let state) = callback.event { states.append(state) } })
      defer { coordinator.dispose() }
      func load(_ id: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
          coordinator.load(.init(source: .init(uri: server.url("/movie.mpd").absoluteString, kind: .network, formatHint: .dash)),
            identity: .init(sessionId: id, loadRequestId: id), willCommit: { _ in }, didCommit: {}, didRollback: {},
            completion: { c.resume(with: $0.mapError { $0 as Error }) })
        }
      }
      try await load("accepted")
      player.measuredTime = CMTime(value: 1_000_500, timescale: 1_000_000)
      let oldItem = player.currentItem
      var result: Result<Void, NativePlayerError>?
      coordinator.execute(.videoTrack("dash-video-w640-h360-b1000")) { result = $0 }
      await fulfillment(of: [entered], timeout: 2)
      XCTAssertFalse(player.landOnSeek)
      try coordinator.executeSynchronous(.seek(2_000))
      let superseded = try XCTUnwrap(player.seekCompletion)
      try coordinator.executeSynchronous(.seek(targetMs))
      let retired = try XCTUnwrap(player.seekCompletion)
      superseded(false)
      for _ in 0..<8 { await Task.yield() }
      coordinator.emitState()
      XCTAssertEqual(states.last?.positionMs, 1_000, "Ordinary pending seek must still publish measured time")
      XCTAssertTrue(player.currentItem === oldItem)
      player.resetClockOnReplacement = true
      release.signal()
      try await AppleHostCharacterizations.waitFor { result != nil }
      try result?.get()
      XCTAssertFalse(player.currentItem === oldItem)
      XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), CMTime(value: targetMs, timescale: 1_000)), 0)
      XCTAssertEqual(states.last?.videoSelection.fixedTrackId, "dash-video-w640-h360-b1000")
      XCTAssertEqual(states.last?.videoTracks.map(\.width), [640])
      let transferred = try XCTUnwrap(player.seekCompletion)
      retired(true)
      for _ in 0..<8 { await Task.yield() }
      coordinator.emitState()
      XCTAssertEqual(states.last?.positionMs, targetMs, "Retired item completion cannot clear the transferred anchor")
      try coordinator.executeSynchronous(.seek(6_000))
      let latest = try XCTUnwrap(player.seekCompletion)
      transferred(false)
      for _ in 0..<8 { await Task.yield() }
      coordinator.emitState()
      XCTAssertEqual(states.last?.positionMs, 6_000, "Superseded replacement seek cannot clear the newest anchor")
      player.measuredTime = CMTime(value: 6_001_500, timescale: 1_000_000)
      latest(true)
      for _ in 0..<8 { await Task.yield() }
      result = nil
      coordinator.execute(.constraints(.unconstrained)) { result = $0 }
      try await AppleHostCharacterizations.waitFor { result != nil }
      try result?.get()
      XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), CMTime(value: 6_001_500, timescale: 1_000_000)), 0,
        "Completed user seek no longer overrides the measured fractional clock")
      try coordinator.executeSynchronous(.seek(7_000))
      let stoppedSeek = try XCTUnwrap(player.seekCompletion)
      coordinator.stop()
      try await load("after-stop")
      stoppedSeek(true)
      for _ in 0..<8 { await Task.yield() }
      player.measuredTime = CMTime(value: 2_001_500, timescale: 1_000_000)
      result = nil
      coordinator.execute(.constraints(.init(maxWidth: 640, maxHeight: nil, maxBitrate: nil))) { result = $0 }
      try await AppleHostCharacterizations.waitFor { result != nil }
      try result?.get()
      XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), CMTime(value: 2_001_500, timescale: 1_000_000)), 0,
        "Stop and new Load cannot retain a retired user seek")
    }
  }

  @MainActor
  func testRuntimeCapsSupersedingNoOpAndLifecycleCancelPendingExactlyOnce() async throws {
    for action in ["newer", "noop", "stop", "dispose", "deactivate", "memory", "load"] {
      let entered = expectation(description: "pending \(action)")
      let release = DispatchSemaphore(value: 0); defer { release.signal() }
      let server = try DashHTTPServer(); defer { server.close() }
      let data = mpd; server.handler = { _ in (200, [:], data) }
      let player = AVPlayer(), output = AppleTestTexture()
      var calls = 0
      let coordinator = YlAppleSessionCoordinator(playerId: 99,
        services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), textureOwner: .init(output: output, onFrame: { _ in }),
        avPlayer: player, beforeDashCapsPreparation: { token in
          calls += 1
          if calls == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
          try token.throwIfCancelled()
        }, emit: { _, _ in })
      defer { coordinator.dispose() }
      func load(_ id: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
          coordinator.load(.init(source: .init(uri: server.url("/movie.mpd").absoluteString, kind: .network, formatHint: .dash)),
            identity: .init(sessionId: id, loadRequestId: id), willCommit: { _ in }, didCommit: {}, didRollback: {},
            completion: { c.resume(with: $0.mapError { $0 as Error }) })
        }
      }
      try await load("stable")
      let old = player.currentItem
      var results: [Result<Void, NativePlayerError>] = []
      coordinator.execute(.constraints(.init(maxWidth: 640, maxHeight: nil, maxBitrate: nil))) { results.append($0) }
      await fulfillment(of: [entered], timeout: 2)
      var second: Result<Void, NativePlayerError>?
      switch action {
      case "newer": coordinator.execute(.constraints(.init(maxWidth: 320, maxHeight: nil, maxBitrate: nil))) { second = $0 }
      case "noop": coordinator.execute(.constraints(.unconstrained)) { second = $0 }
      case "stop": coordinator.stop()
      case "dispose": coordinator.dispose()
      case "deactivate": coordinator.deactivate()
      case "memory": coordinator.handleMemoryWarning()
      default: try await load("next")
      }
      XCTAssertEqual(results.count, 1)
      if case .failure(let error) = results.first { XCTAssertEqual(error.code, "network.cancelled") }
      else { XCTFail("Pending caps must be cancelled") }
      if action == "noop" { XCTAssertTrue(player.currentItem === old); try second?.get() }
      release.signal()
      if action == "newer" { try await AppleHostCharacterizations.waitFor { second != nil }; try second?.get(); XCTAssertEqual(coordinator.acceptedVideoConstraints.maxWidth, 320) }
      for _ in 0..<12 { await Task.yield() }
      XCTAssertEqual(results.count, 1)
    }
  }

  @MainActor
  func testFixedSelectionSharesCapsSupersessionAndLifecycleCancellation() async throws {
    for action in ["newer", "noop", "caps", "stop", "dispose", "deactivate", "memory", "load"] {
      let entered = expectation(description: "pending \(action)")
      let release = DispatchSemaphore(value: 0); defer { release.signal() }
      let server = try DashHTTPServer(); defer { server.close() }
      let data = twoQualityMPD; server.handler = { _ in (200, [:], data) }
      let player = AVPlayer(), output = AppleTestTexture()
      var calls = 0
      let coordinator = YlAppleSessionCoordinator(playerId: 99,
        services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), textureOwner: .init(output: output, onFrame: { _ in }),
        avPlayer: player, beforeDashCapsPreparation: { token in
          calls += 1
          if calls == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
          try token.throwIfCancelled()
        }, emit: { _, _ in })
      defer { coordinator.dispose() }
      func load(_ id: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
          coordinator.load(.init(source: .init(uri: server.url("/movie.mpd").absoluteString, kind: .network, formatHint: .dash)),
            identity: .init(sessionId: id, loadRequestId: id), willCommit: { _ in }, didCommit: {}, didRollback: {},
            completion: { c.resume(with: $0.mapError { $0 as Error }) })
        }
      }
      try await load("stable")
      let old = player.currentItem
      var results: [Result<Void, NativePlayerError>] = []
      coordinator.execute(.videoTrack("dash-video-w640-h360-b2000")) { results.append($0) }
      await fulfillment(of: [entered], timeout: 2)
      var second: Result<Void, NativePlayerError>?
      switch action {
      case "newer": coordinator.execute(.videoTrack("dash-video-w320-h180-b1000")) { second = $0 }
      case "caps": coordinator.execute(.constraints(.init(maxWidth: 320, maxHeight: nil, maxBitrate: nil))) { second = $0 }
      case "noop": coordinator.execute(.videoTrack(nil)) { second = $0 }
      case "stop": coordinator.stop()
      case "dispose": coordinator.dispose()
      case "deactivate": coordinator.deactivate()
      case "memory": coordinator.handleMemoryWarning()
      default: try await load("next")
      }
      XCTAssertEqual(results.count, 1)
      if case .failure(let error) = results.first { XCTAssertEqual(error.code, "network.cancelled") }
      else { XCTFail("Pending caps must be cancelled") }
      if action == "noop" { XCTAssertTrue(player.currentItem === old); try second?.get() }
      release.signal()
      if action == "newer" || action == "caps" { try await AppleHostCharacterizations.waitFor { second != nil }; try second?.get() }
      for _ in 0..<12 { await Task.yield() }
      XCTAssertEqual(results.count, 1)
    }
  }

  @MainActor
  func testFixedSelectionConfirmedLandingFallbackIsStickyAndRestorationRetainsPolicy() async throws {
    let data = changingCatalogMPD
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { _ in (200, [:], data) }
    let player = DashCatalogClockPlayer(), output = AppleTestTexture()
    var states: [YlNativeState] = []
    let coordinator = YlAppleSessionCoordinator(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), textureOwner: .init(output: output, onFrame: { _ in }),
      avPlayer: player, emit: { _, callback in if case .state(let state) = callback.event { states.append(state) } })
    defer { coordinator.dispose() }
    func load(_ id: String) async throws {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        coordinator.load(.init(source: .init(uri: server.url("/movie.mpd").absoluteString, kind: .network, formatHint: .dash)),
          identity: .init(sessionId: id, loadRequestId: id), willCommit: { _ in }, didCommit: {}, didRollback: {},
          completion: { c.resume(with: $0.mapError { $0 as Error }) })
      }
    }
    func command(_ command: YlApplePlaybackCommand) async throws {
      try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
        coordinator.execute(command) { c.resume(with: $0.mapError { $0 as Error }) }
      }
    }
    try await load("stable")
    try await command(.videoTrack("dash-video-w640-h360-b1000"))
    XCTAssertEqual(states.last?.videoSelection.fixedTrackId, "dash-video-w640-h360-b1000")
    let fixedItem = player.currentItem
    let fixedLoader = try XCTUnwrap((fixedItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    // Reading the whole future playlist must not change the current mode.
    _ = read(fixedLoader, try child(read(fixedLoader, try fixedLoader.encodedAssetURL()).received))
    coordinator.emitState()
    XCTAssertEqual(states.last?.videoSelection.reason, "user")
    try coordinator.executeSynchronous(.seek(5_000))
    let retired = try XCTUnwrap(player.seekCompletion)
    player.measuredTime = CMTime(value: 5_000_000, timescale: 1_000_000)
    coordinator.emitState()
    XCTAssertTrue(player.currentItem === fixedItem)
    XCTAssertEqual(states.last?.videoTracks.map(\.width), [640], "Unlanded seek retains coherent fixed catalog")
    XCTAssertEqual(states.last?.videoSelection.fixedTrackId, "dash-video-w640-h360-b1000")
    retired(false)
    for _ in 0..<12 { await Task.yield() }
    XCTAssertTrue(player.currentItem === fixedItem, "Cancelled seek completion cannot trigger PD-01")
    XCTAssertEqual(states.last?.videoSelection.reason, "user")
    XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), .zero), 0, "Cancelled landing recovers without another user command")
    player.measuredTime = .zero
    player.seekCompletion?(true)
    for _ in 0..<8 { await Task.yield() }
    XCTAssertEqual(states.last?.videoSelection.reason, "user")
    try coordinator.executeSynchronous(.seek(5_000))
    player.measuredTime = CMTime(value: 5_000, timescale: 1_000)
    player.seekCompletion?(true)
    for _ in 0..<12 { await Task.yield() }
    XCTAssertFalse(player.currentItem === fixedItem)
    XCTAssertNil(states.last?.videoSelection.fixedTrackId)
    XCTAssertEqual(states.last?.videoSelection.reason, "trackUnavailable")
    XCTAssertEqual(states.last?.videoTracks.map(\.width), [320])
    let automaticItem = player.currentItem
    player.seekCompletion?(true)
    for _ in 0..<8 { await Task.yield() }
    player.landOnSeek = true
    try coordinator.executeSynchronous(.seek(1_000))
    player.seekCompletion?(true)
    for _ in 0..<8 { await Task.yield() }
    coordinator.emitState()
    XCTAssertTrue(player.currentItem === automaticItem)
    XCTAssertEqual(states.last?.videoSelection.reason, "trackUnavailable")
    XCTAssertNil(states.last?.videoSelection.fixedTrackId)
    XCTAssertEqual(states.last?.videoTracks.map(\.width), [640])
    coordinator.deactivate()
    do { try await command(.videoTrack("dash-video-w640-h360-b1000")); XCTFail("Inactive changed mode must reject") }
    catch { XCTAssertEqual((error as? NativePlayerError)?.code, "policy.video_selection_unsupported") }
    try await command(.play)
    player.seekCompletion?(true)
    for _ in 0..<8 { await Task.yield() }
    coordinator.emitState()
    XCTAssertEqual(states.last?.videoSelection.reason, "trackUnavailable")
    XCTAssertEqual(server.requests.filter { $0.path == "/movie.mpd" }.count, 1)
    coordinator.stop(); try await load("new")
    XCTAssertEqual(states.last?.videoSelection.reason, "initial")
    XCTAssertNil(states.last?.videoSelection.fixedTrackId)
    retired(true)
    for _ in 0..<8 { await Task.yield() }
    XCTAssertEqual(states.last?.videoSelection.reason, "initial")
  }

  @MainActor
  func testFixedRecoveryFailureAndTimeoutSurfaceSafeFailureWithoutAuto() async throws {
    for timeout in [false, true] {
      let data = changingCatalogMPD
      let config = DashLoaderProtocol.configuration { $0.respond(data) }
      let player = DashCatalogClockPlayer()
      var states: [YlNativeState] = [], failures: [NativePlayerError] = []
      let backend = YlAvPlayerBackend(playerId: 99,
        services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, emit: {
          if case .state(let state) = $0.event { states.append(state) }
          if case .failure(let error) = $0.event { failures.append(error) }
        })
      defer { backend.dispose() }
      let source = YlAppleSourceDescriptor(uri: origin.absoluteString, kind: .network, formatHint: .dash)
      let original = try prepare(config), snapshot = try XCTUnwrap(original.loader.dashSnapshot)
      try backend.stagePreparedHls(source: source, prepared: original, resume: false); try backend.activate()
      let fixed = try YlPreparedHlsAsset(originURL: origin, isDash: true, fixedTrackId: "dash-video-w640-h360-b1000",
        headers: [:], configuration: .init(map: [:]), cancellationToken: .init(), dashSnapshot: snapshot)
      fixed.automaticCandidate = try YlPreparedHlsAsset(originURL: origin, isDash: true,
        headers: [:], configuration: .init(map: [:]), cancellationToken: .init(), dashSnapshot: snapshot)
      try backend.replaceActiveDash(source: source, prepared: fixed, selection: .init(fixedTrackId: "dash-video-w640-h360-b1000", reason: "user"))
      try backend.seek(toMs: 5_000)
      player.measuredTime = CMTime(value: 5_000, timescale: 1_000)
      player.seekCompletion?(false)
      for _ in 0..<8 { await Task.yield() }
      XCTAssertEqual(CMTimeCompare(try XCTUnwrap(player.requestedSeek), .zero), 0)
      if timeout { try await Task.sleep(nanoseconds: 5_200_000_000) }
      else { player.seekCompletion?(false); for _ in 0..<8 { await Task.yield() } }
      XCTAssertEqual(failures.map(\.code), ["source.seek_failed"])
      XCTAssertEqual(states.last?.status, "error")
      XCTAssertEqual(states.last?.videoSelection.reason, "user")
      XCTAssertEqual(states.last?.videoTracks.map(\.width), [640])
      XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
      player.seekCompletion?(true)
      for _ in 0..<8 { await Task.yield() }
      XCTAssertEqual(failures.count, 1)
    }
  }

  @MainActor
  func testFixedLeaseRollbackRebuildsSpareAndNaturalPeriodFallback() async throws {
    let data = changingCatalogMPD
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { _ in (200, [:], data) }
    let player = DashCatalogClockPlayer(), output = AppleTestTexture()
    var states: [YlNativeState] = []
    let coordinator = YlAppleSessionCoordinator(playerId: 99,
      services: .init(platform: .ios, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), textureOwner: .init(output: output, onFrame: { _ in }),
      avPlayer: player, emit: { _, callback in if case .state(let state) = callback.event { states.append(state) } })
    defer { coordinator.dispose() }
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      coordinator.load(.init(source: .init(uri: server.url("/movie.mpd").absoluteString, kind: .network, formatHint: .dash)),
        identity: .init(sessionId: "stable", loadRequestId: "load"), willCommit: { _ in }, didCommit: {}, didRollback: {},
        completion: { c.resume(with: $0.mapError { $0 as Error }) })
    }
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
      coordinator.execute(.videoTrack("dash-video-w640-h360-b1000")) { c.resume(with: $0.mapError { $0 as Error }) }
    }
    let old = player.currentItem
    coordinator.quiesceForHardwareDecoderLease()
    XCTAssertNil(player.currentItem)
    coordinator.restoreAfterHardwareDecoderRollback(forcePlay: false)
    try await AppleHostCharacterizations.waitFor { player.currentItem != nil }
    XCTAssertFalse(player.currentItem === old)
    player.seekCompletion?(true)
    for _ in 0..<8 { await Task.yield() }
    XCTAssertEqual(states.last?.videoSelection.fixedTrackId, "dash-video-w640-h360-b1000")
    XCTAssertFalse(coordinator.currentPlaybackIntent)
    let restored = player.currentItem
    player.measuredTime = CMTime(value: 5_000, timescale: 1_000)
    player.tick?(player.measuredTime)
    XCTAssertFalse(player.currentItem === restored)
    XCTAssertEqual(states.last?.videoSelection.reason, "trackUnavailable")
    XCTAssertNil(states.last?.videoSelection.fixedTrackId)
    XCTAssertEqual(server.requests.filter { $0.path == "/movie.mpd" }.count, 1)
  }

  @MainActor
  func testFixedFrameCannotPublishAfterFallbackRetiresItsItem() async throws {
    let data = changingCatalogMPD
    let player = DashCatalogClockPlayer(), output = AppleTestTexture()
    let pixels = DashPixelOutput(width: 640, height: 360)
    var tick: (() -> Void)?, states: [YlNativeState] = []
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, makeVideoOutput: { _ in pixels }, emit: {
        if case .state(let state) = $0.event { states.append(state) }
      })
    defer { backend.dispose() }
    let source = YlAppleSourceDescriptor(uri: origin.absoluteString, kind: .network, formatHint: .dash)
    let original = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    let snapshot = try XCTUnwrap(original.loader.dashSnapshot)
    try backend.stagePreparedHls(source: source, prepared: original, resume: false); try backend.activate()
    let fixed = try YlPreparedHlsAsset(originURL: origin, isDash: true, fixedTrackId: "dash-video-w640-h360-b1000",
      headers: [:], configuration: .init(map: [:]), cancellationToken: .init(), dashSnapshot: snapshot)
    fixed.automaticCandidate = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      headers: [:], configuration: .init(map: [:]), cancellationToken: .init(), dashSnapshot: snapshot)
    try backend.replaceActiveDash(source: source, prepared: fixed, selection: .init(fixedTrackId: "dash-video-w640-h360-b1000", reason: "user"))
    // A previous-Period output sample can overlap the authoritative clock's
    // boundary. The metadata/state sample synchronously retires this item.
    player.measuredTime = CMTime(value: 5_000, timescale: 1_000)
    pixels.measuredItemTime = .zero
    tick?()
    XCTAssertEqual(states.last?.videoSelection.reason, "trackUnavailable")
    XCTAssertTrue(output.frames.isEmpty, "The retired fixed item must not publish after automatic installation")
  }

  @MainActor
  func testFixedOutputRejectsFuturePeriodAndContradictoryPixelsBeforePublication() async throws {
    let data = changingCatalogMPD
    let player = DashCatalogClockPlayer(), output = AppleTestTexture()
    let pixels = DashPixelOutput(width: 320, height: 180)
    var states: [YlNativeState] = [], failures: [NativePlayerError] = []
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, makeVideoOutput: { _ in pixels }, emit: {
        if case .state(let state) = $0.event { states.append(state) }
        if case .failure(let error) = $0.event { failures.append(error) }
      })
    defer { backend.dispose() }
    let source = YlAppleSourceDescriptor(uri: origin.absoluteString, kind: .network, formatHint: .dash)
    let original = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    let snapshot = try XCTUnwrap(original.loader.dashSnapshot)
    try backend.stagePreparedHls(source: source, prepared: original, resume: false); try backend.activate()
    let fixed = try YlPreparedHlsAsset(originURL: origin, isDash: true, fixedTrackId: "dash-video-w640-h360-b1000",
      headers: [:], configuration: .init(map: [:]), cancellationToken: .init(), dashSnapshot: snapshot)
    fixed.automaticCandidate = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      headers: [:], configuration: .init(map: [:]), cancellationToken: .init(), dashSnapshot: snapshot)
    try backend.replaceActiveDash(source: source, prepared: fixed, selection: .init(fixedTrackId: "dash-video-w640-h360-b1000", reason: "user"))
    pixels.measuredItemTime = CMTime(value: 5_000, timescale: 1_000)
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
    for _ in 0..<8 { await Task.yield() }
    XCTAssertTrue(failures.isEmpty, "Prefetched future Period is not current authority")
    XCTAssertEqual(states.last?.videoSelection.reason, "user")
    XCTAssertEqual(states.last?.videoTracks.map(\.width), [640])
    pixels.measuredItemTime = .zero
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
    for _ in 0..<8 { await Task.yield() }
    XCTAssertEqual(failures.map(\.code), ["decoder.quality_constraint_unsupported"])
    XCTAssertNil(states.last?.geometry)
    XCTAssertTrue(output.frames.isEmpty)
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
  }

  @MainActor
  func testFixedAutomaticInstallationFailureRetainsTruthfulModeAndReleasesSpare() async throws {
    let data = changingCatalogMPD
    let player = DashCatalogClockPlayer()
    var states: [YlNativeState] = [], failures: [NativePlayerError] = []
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: AppleTestTexture(), makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), player: player, emit: {
        if case .state(let state) = $0.event { states.append(state) }
        if case .failure(let error) = $0.event { failures.append(error) }
      })
    defer { backend.dispose() }
    let source = YlAppleSourceDescriptor(uri: origin.absoluteString, kind: .network, formatHint: .dash)
    let original = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    let snapshot = try XCTUnwrap(original.loader.dashSnapshot)
    try backend.stagePreparedHls(source: source, prepared: original, resume: false); try backend.activate()
    let fixed = try YlPreparedHlsAsset(originURL: origin, isDash: true, fixedTrackId: "dash-video-w640-h360-b1000",
      headers: [:], configuration: .init(map: [:]), cancellationToken: .init(), dashSnapshot: snapshot)
    let automatic = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      headers: [:], configuration: .init(map: [:]), cancellationToken: .init(), dashSnapshot: snapshot)
    fixed.automaticCandidate = automatic
    try backend.replaceActiveDash(source: source, prepared: fixed, selection: .init(fixedTrackId: "dash-video-w640-h360-b1000", reason: "user"))
    try backend.play()
    backend.beforeAudioOutput = { throw YlNativeVideoSelection.unsupported }
    player.measuredTime = CMTime(value: 5_000, timescale: 1_000)
    backend.emitState()
    XCTAssertEqual(failures.count, 1)
    XCTAssertEqual(states.last?.status, "error")
    XCTAssertEqual(states.last?.videoSelection.reason, "user")
    XCTAssertEqual(states.last?.videoTracks.map(\.width), [640])
    XCTAssertNil(automatic.loader.dashSnapshot)
    backend.emitState()
    XCTAssertEqual(failures.count, 1)
  }

  @MainActor
  func testFixedSelectionHostProjectsHighAndKeepsFullCatalog() async throws {
    let one = String(data: mpd, encoding: .utf8)!
    let high = "<Representation id=\"high\" bandwidth=\"2000\" codecs=\"avc1.64001f\" width=\"640\" height=\"360\"><SegmentTemplate initialization=\"high-init.mp4\" media=\"high-$Number$.m4s\" duration=\"2\"/></Representation>"
    let data = Data(one.replacingOccurrences(of: "</AdaptationSet>", with: high + "</AdaptationSet>").utf8)
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { _ in (200, [:], data) }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    let loaded = try await fixture.host.load(request: AppleHostFixture.request("fixed", url: server.url("/movie.mpd").absoluteString, format: .dash))
    let originalItem = fixture.av.currentItem
    do {
      try await fixture.host.selectVideoTrack(command: .init(sessionId: loaded.sessionId, trackId: "private-missing-id"))
      XCTFail("An unknown ID must reject")
    } catch let error as PigeonError { XCTAssertEqual(error.code, "policy.video_selection_unsupported") }
    XCTAssertTrue(fixture.av.currentItem === originalItem)
    try await fixture.host.selectVideoTrack(command: .init(sessionId: loaded.sessionId, trackId: "dash-video-w640-h360-b2000"))
    let selectedItem = fixture.av.currentItem
    try await fixture.host.selectVideoTrack(command: .init(sessionId: loaded.sessionId, trackId: "dash-video-w640-h360-b2000"))
    XCTAssertTrue(fixture.av.currentItem === selectedItem)
    let loader = try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    XCTAssertEqual(loader.videoCatalog?.tracks(at: 0).map(\.id), ["dash-video-w320-h180-b1000", "dash-video-w640-h360-b2000"])
    let master = read(loader, try loader.encodedAssetURL())
    let media = String(data: read(loader, try child(master.received)).received, encoding: .utf8)!
    XCTAssertTrue(media.contains("high-init.mp4"))
    XCTAssertFalse(media.contains("/init.mp4"))
    XCTAssertEqual(server.requests.filter { $0.path == "/movie.mpd" }.count, 1)
    let accepted = fixture.av.currentItem
    do {
      try await fixture.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxWidth: 320)))
      XCTFail("Fixed high cannot be silently cleared by a cap")
    } catch let error as PigeonError { XCTAssertEqual(error.code, "decoder.quality_constraint_unsupported") }
    XCTAssertTrue(fixture.av.currentItem === accepted)
    try await fixture.host.selectVideoTrack(command: .init(sessionId: loaded.sessionId, trackId: nil))
    let auto = try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    let autoMaster = String(data: read(auto, try auto.encodedAssetURL()).received, encoding: .utf8)!
    XCTAssertEqual(autoMaster.components(separatedBy: "#EXT-X-STREAM-INF:").count - 1, 2)
  }

  @MainActor
  func testRuntimeCapsClearRestoresAcceptedOriginalWithoutRefetch() async throws {
    let one = String(data: mpd, encoding: .utf8)!
    let high = "<Representation id=\"high\" bandwidth=\"2000\" codecs=\"avc1.64001f\" width=\"640\" height=\"360\"><SegmentTemplate initialization=\"init.mp4\" media=\"seg-$Number$.m4s\" duration=\"2\"/></Representation>"
    let data = Data(one.replacingOccurrences(of: "</AdaptationSet>", with: high + "</AdaptationSet>").utf8)
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { _ in (200, [:], data) }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    let loaded = try await fixture.host.load(request: AppleHostFixture.request("runtime", url: server.url("/movie.mpd").absoluteString, format: .dash, width: 320))
    let old = fixture.av.currentItem
    try await fixture.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init()))
    XCTAssertFalse(fixture.av.currentItem === old)
    XCTAssertEqual(fixture.host.sessionId, loaded.sessionId)
    XCTAssertEqual(fixture.host.acceptedVideoConstraints, .unconstrained)
    let loader = try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    XCTAssertEqual(loader.videoCatalog?.tracks(at: 0).count, 2)
    XCTAssertEqual(server.requests.filter { $0.path == "/movie.mpd" }.count, 1)
    try await fixture.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxWidth: 320)))
    let capped = try XCTUnwrap(fixture.av.currentItem)
    XCTAssertEqual(fixture.host.acceptedVideoConstraints.maxWidth, 320)
    fixture.host.suspend(); fixture.host.resume()
    try await AppleHostCharacterizations.waitFor { fixture.av.currentItem != nil && fixture.av.currentItem !== capped }
    try await fixture.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init()))
    let restored = try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    XCTAssertEqual(restored.videoCatalog?.tracks(at: 0).count, 2)
    XCTAssertEqual(server.requests.filter { $0.path == "/movie.mpd" }.count, 1)
  }

  @MainActor
  func testLoadCapsRuntimeMutationFailsBeforeAcceptedIntentAndSurvivesRestore() async throws {
    let data = mpd
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { _ in (200, [:], data) }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    let loaded = try await fixture.host.load(request: AppleHostFixture.request("caps", url: server.url("/movie.mpd").absoluteString, format: .dash, width: 320))
    try await fixture.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxWidth: 320)))
    do {
      try await fixture.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init(maxWidth: 160)))
      XCTFail("An infeasible cap must fail before acceptance")
    } catch let error as PigeonError { XCTAssertEqual(error.code, "decoder.quality_constraint_unsupported") }
    XCTAssertEqual(fixture.host.acceptedVideoConstraints.maxWidth, 320)
    let old = fixture.av.currentItem
    do {
      _ = try await fixture.host.load(request: AppleHostFixture.request("empty-candidate", url: server.url("/movie.mpd").absoluteString, format: .dash, width: 319))
      XCTFail("An ineligible replacement must not commit")
    } catch let error as PigeonError {
      XCTAssertEqual(error.code, "decoder.quality_constraint_unsupported")
    }
    XCTAssertTrue(fixture.av.currentItem === old)
    XCTAssertEqual(fixture.host.sessionId, loaded.sessionId)
    XCTAssertEqual(fixture.host.acceptedVideoConstraints.maxWidth, 320)
    fixture.host.suspend()
    do {
      try await fixture.host.setVideoConstraints(command: .init(sessionId: loaded.sessionId, constraints: .init()))
      XCTFail("Inactive changes require reload")
    } catch let error as PigeonError { XCTAssertEqual(error.code, "policy.video_constraints_reload_required") }
    fixture.host.resume()
    try await AppleHostCharacterizations.waitFor { fixture.av.currentItem != nil && fixture.av.currentItem !== old }
    let restored = try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    XCTAssertEqual(restored.videoConstraints.maxWidth, 320)
    let next = try await fixture.host.load(request: AppleHostFixture.request("new", url: server.url("/movie.mpd").absoluteString, format: .dash))
    XCTAssertNotEqual(next.sessionId, loaded.sessionId)
    XCTAssertNil(fixture.host.acceptedVideoConstraints.maxWidth)
    try await fixture.host.stop()
    XCTAssertNil(fixture.host.acceptedVideoConstraints.maxWidth)
  }

  func testLoadCapsLoaderRejectsIneligibleCandidateBeforePublishingAssetAndRedactsErrors() throws {
    let data = mpd
    XCTAssertThrowsError(try YlPreparedHlsAsset(originURL: origin, isDash: true,
      videoConstraints: .init(maxWidth: nil, maxHeight: 179, maxBitrate: nil), headers: ["Authorization": "secret"],
      configuration: .init(map: [:]), cancellationToken: .init(),
      sessionConfiguration: DashLoaderProtocol.configuration { $0.respond(data) })) { error in
        let safe = YlAppleSafeDiagnostics.failure(error, scope: .command)
        XCTAssertEqual(safe.code, "decoder.quality_constraint_unsupported")
        XCTAssertTrue(safe.message.contains("constraints"))
        XCTAssertFalse(safe.message.contains("private")); XCTAssertFalse(safe.message.contains("secret"))
      }
    XCTAssertEqual(DashLoaderProtocol.captured.count, 1)
    let safe = YlAppleSafeDiagnostics.failure(NativePlayerError(category: "unsupported",
      code: "policy.video_constraints_reload_required", message: "https://private.test?token=secret"), scope: .command)
    XCTAssertEqual(safe.code, "policy.video_constraints_reload_required")
    XCTAssertTrue(safe.message.contains("Reload")); XCTAssertFalse(safe.retryable)
    XCTAssertFalse(safe.message.contains("private")); XCTAssertFalse(safe.message.contains("secret"))
  }

  @MainActor
  func testLoadCapsPixelAspectRatioRejectsAndRetiredFailureCannotPoisonNewItem() async throws {
    let data = mpd
    let prepared = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      videoConstraints: .init(maxWidth: 320, maxHeight: 180, maxBitrate: nil), headers: [:],
      configuration: .init(map: [:]), cancellationToken: .init(),
      sessionConfiguration: DashLoaderProtocol.configuration { $0.respond(data) })
    let pixels = DashPixelOutput(width: 320, height: 180)
    CVBufferSetAttachment(pixels.buffer, kCVImageBufferPixelAspectRatioKey,
      [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 2, kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1] as CFDictionary, .shouldPropagate)
    let output = AppleTestTexture()
    var tick: (() -> Void)?, failures = 0, frames = 0
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), makeVideoOutput: { _ in pixels }, emit: {
        if case .failure = $0.event { failures += 1 }; if case .firstFrame = $0.event { frames += 1 }
      })
    defer { backend.dispose() }
    try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash), prepared: prepared, resume: false)
    try backend.activate()
    XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
    // Replace before the queued failure reaches main: it belongs to the old item.
    try backend.open(.init(uri: "https://origin.test/new.mp4", kind: .network, formatHint: .mp4))
    for _ in 0..<12 { await Task.yield() }
    XCTAssertEqual(failures, 0)
    XCTAssertNotNil(backend.copyPixelBuffer()?.takeRetainedValue())
    tick?()
    XCTAssertEqual(output.frames.count, 1); XCTAssertEqual(frames, 1)
  }

  @MainActor
  func testLoadCapsExactPixelBoundaryPublishesAndBackendRejectsChangedTuple() throws {
    let data = mpd
    let prepared = try YlPreparedHlsAsset(originURL: origin, isDash: true,
      videoConstraints: .init(maxWidth: 320, maxHeight: 180, maxBitrate: nil), headers: [:],
      configuration: .init(map: [:]), cancellationToken: .init(),
      sessionConfiguration: DashLoaderProtocol.configuration { $0.respond(data) })
    let pixels = DashPixelOutput(width: 320, height: 180), output = AppleTestTexture()
    var tick: (() -> Void)?, frames = 0
    let backend = YlAvPlayerBackend(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]), makeVideoOutput: { _ in pixels }, emit: { if case .firstFrame = $0.event { frames += 1 } })
    defer { backend.dispose() }
    try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash), prepared: prepared, resume: false)
    try backend.activate()
    XCTAssertNoThrow(try backend.setVideoConstraints(.init(maxWidth: 320, maxHeight: 180, maxBitrate: nil)))
    XCTAssertThrowsError(try backend.setVideoConstraints(.unconstrained))
    XCTAssertNotNil(backend.copyPixelBuffer()?.takeRetainedValue())
    tick?(); XCTAssertEqual(output.frames.count, 1); XCTAssertEqual(frames, 1)
    backend.stop(); XCTAssertNoThrow(try backend.setVideoConstraints(.unconstrained))
  }

  @MainActor
  func testLoadCapsLegacyNilOptionsCaptureOnMainAndPendingRestorationRejectsChanges() async throws {
    let data = mpd, held = expectation(description: "legacy candidate preparing")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { [weak server] _ in if server?.requests.count == 1 { held.fulfill(); _ = release.wait(timeout: .now() + 6) }; return (200, [:], data) }
    let player = AVPlayer(), output = AppleTestTexture()
    let coordinator = YlAppleSessionCoordinator(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]),
      textureOwner: .init(output: output, onFrame: { _ in }), avPlayer: player, emit: { _, _ in })
    defer { coordinator.dispose() }
    func load(_ source: YlAppleSourceDescriptor, _ id: String) async throws {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        coordinator.load(.init(source: source), identity: .init(sessionId: id, loadRequestId: id),
          willCommit: { _ in }, didCommit: {}, didRollback: {}, completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
      }
    }
    try await load(.init(uri: "https://origin.test/a.mp4", kind: .network, formatHint: .mp4), "old")
    try coordinator.executeSynchronous(.constraints(.init(maxWidth: 320, maxHeight: nil, maxBitrate: nil)))
    let pending = Task { try await load(.init(uri: server.url("/movie.mpd").absoluteString, kind: .network, formatHint: .dash), "dash") }
    await fulfillment(of: [held], timeout: 3)
    try coordinator.executeSynchronous(.constraints(.init(maxWidth: 640, maxHeight: nil, maxBitrate: nil)))
    release.signal(); try await pending.value
    XCTAssertEqual(coordinator.acceptedVideoConstraints.maxWidth, 320)
    XCTAssertEqual((player.currentItem?.asset as? AVURLAsset).flatMap { $0.resourceLoader.delegate as? YlHlsResourceLoader }?.videoConstraints.maxWidth, 320)
    coordinator.deactivate()
    coordinator.restoreAfterHardwareDecoderRollback(forcePlay: false)
    XCTAssertThrowsError(try coordinator.executeSynchronous(.constraints(.unconstrained))) { error in
      XCTAssertEqual((error as? NativePlayerError)?.code, "policy.video_constraints_reload_required")
    }
    XCTAssertNoThrow(try coordinator.executeSynchronous(.constraints(.init(maxWidth: 320, maxHeight: nil, maxBitrate: nil))))
    XCTAssertEqual(coordinator.acceptedVideoConstraints.maxWidth, 320)
    try await AppleHostCharacterizations.waitFor { coordinator.isActive }
    XCTAssertEqual(coordinator.acceptedVideoConstraints.maxWidth, 320)
  }

  @MainActor
  func testLoadCapsLateMetadataCannotRotatePublishedPixelsBeyondCapsOrErasePAR() async throws {
    for invalidMetadata in [false, true] {
      let data = mpd
      let prepared = try YlPreparedHlsAsset(originURL: origin, isDash: true,
        videoConstraints: .init(maxWidth: 640, maxHeight: 180, maxBitrate: nil), headers: [:],
        configuration: .init(map: [:]), cancellationToken: .init(),
        sessionConfiguration: DashLoaderProtocol.configuration { $0.respond(data) })
      let pixels = DashPixelOutput(width: 320, height: 180), output = AppleTestTexture()
      CVBufferSetAttachment(pixels.buffer, kCVImageBufferPixelAspectRatioKey,
        [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 2, kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1] as CFDictionary, .shouldPropagate)
      var tick: (() -> Void)?, failures = 0
      var states: [YlNativeState] = []
      let backend = YlAvPlayerBackend(playerId: 99,
        services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { tick = $0; return AppleTestDisplay() }),
        configuration: .init(map: ["audioPolicy": "appManaged"]), makeVideoOutput: { _ in pixels }, emit: { if case .failure = $0.event { failures += 1 }; if case .state(let state) = $0.event { states.append(state) } })
      defer { backend.dispose() }
      try backend.stagePreparedHls(source: .init(uri: origin.absoluteString, kind: .network, formatHint: .dash), prepared: prepared, resume: false)
      try backend.activate()
      tick?(); XCTAssertEqual(output.frames.count, 1)
      let plainMetadata = YlVideoGeometryResolver.resolve(encodedSize: .init(width: 320, height: 180), cleanAperture: nil, pixelAspectRatio: 1, rotationDegrees: 0)
      XCTAssertTrue(backend.applyMetadataGeometry(plainMetadata, hasVideoTracks: true))
      backend.emitState()
      XCTAssertEqual(states.last?.geometry?.pixelAspectRatio, 2)
      let metadata = YlVideoGeometryResolver.resolve(encodedSize: .init(width: 320, height: 180), cleanAperture: nil, pixelAspectRatio: 1, rotationDegrees: 90)
      XCTAssertFalse(backend.applyMetadataGeometry(invalidMetadata ? nil : metadata, hasVideoTracks: true))
      XCTAssertNil(backend.copyPixelBuffer()?.takeRetainedValue())
      tick?(); XCTAssertEqual(output.frames.count, 1)
      for _ in 0..<12 { await Task.yield() }
      XCTAssertEqual(failures, 1)
      XCTAssertFalse(states.contains { $0.geometry?.rotationDegrees == 90 })
    }
  }

  @MainActor
  func testLoadCapsRetainedDashCannotVetoLegacyMp4AfterFallbackChangesAcceptedTuple() async throws {
    let data = mpd
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { _ in (200, [:], data) }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("dash-caps-fallback-\(UUID().uuidString).mkv")
    try AppleHostCharacterizations.fixtureMedia().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let player = AVPlayer(), output = AppleTestTexture()
    var states: [YlNativeState] = []
    let coordinator = YlAppleSessionCoordinator(playerId: 99,
      services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
      configuration: .init(map: ["audioPolicy": "appManaged"]),
      textureOwner: .init(output: output, onFrame: { _ in }), avPlayer: player,
      videoSessionFactory: DashPassiveVTFactory(), emit: { _, callback in if case .state(let state) = callback.event { states.append(state) } })
    defer { coordinator.dispose() }
    func load(_ source: YlAppleSourceDescriptor, _ id: String) async throws {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        coordinator.load(.init(source: source), identity: .init(sessionId: id, loadRequestId: id),
          willCommit: { _ in }, didCommit: {}, didRollback: {}, completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
      }
    }
    for (index, inherited) in [YlAppleVideoConstraints(maxWidth: 640, maxHeight: nil, maxBitrate: nil), .unconstrained].enumerated() {
      try await load(.init(uri: server.url("/movie.mpd").absoluteString, kind: .network, formatHint: .dash,
        loadOptions: .init(videoConstraints: .init(maxWidth: 320, maxHeight: nil, maxBitrate: nil))), "dash-\(index)")
      // Runtime changes are now prepared asynchronously; a new Load still owns its tuple.
      try await load(.init(uri: file.absoluteString, kind: .file, formatHint: .matroska,
        loadOptions: .init(videoConstraints: inherited)), "fallback-\(index)")
      coordinator.emitState()
      guard case .managedFallback? = states.last?.engine else { return XCTFail("The real fallback must be current before returning to AVPlayer") }
      XCTAssertEqual(coordinator.acceptedVideoConstraints, inherited)
      do {
        try await load(.init(uri: "https://origin.test/legacy.mp4", kind: .network, formatHint: .mp4), "legacy-\(index)")
      } catch let error as NativePlayerError {
        return XCTFail("Legacy MP4 Load failed with \(error.code)")
      }
      XCTAssertEqual(coordinator.identity?.sessionId, "legacy-\(index)")
      XCTAssertEqual(coordinator.acceptedVideoConstraints, inherited)
      XCTAssertEqual((player.currentItem?.asset as? AVURLAsset)?.url.absoluteString, "https://origin.test/legacy.mp4")
      XCTAssertEqual(player.currentItem?.preferredMaximumResolution.width, inherited.maxWidth.map(CGFloat.init) ?? 0)
    }
  }

  @MainActor
  func testHeaderedHlsRestoreKeepsLatestPreferencesWhileNewLoadKeepsCapturedTuple() async throws {
    let original = YlAppleVideoConstraints(maxWidth: 320, maxHeight: nil, maxBitrate: nil)
    for restoring in [true, false] {
      for changed in [YlAppleVideoConstraints(maxWidth: 640, maxHeight: nil, maxBitrate: nil), .unconstrained] {
        let held = expectation(description: "HLS preflight held")
        let release = DispatchSemaphore(value: 0); defer { release.signal() }
        let server = try DashHTTPServer(); defer { server.close() }
        let manifest = Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)
        server.handler = { [weak server] request in
          if request.path == "/master.m3u8", server?.requests.filter({ $0.path == "/master.m3u8" }).count == 2 {
            held.fulfill(); _ = release.wait(timeout: .now() + 6)
          }
          return (200, ["Content-Type": "application/vnd.apple.mpegurl"], manifest)
        }
        let player = AVPlayer(), output = AppleTestTexture()
        let coordinator = YlAppleSessionCoordinator(playerId: 99,
          services: .init(platform: .current, textureOutput: output, makeDisplayDriver: { _ in AppleTestDisplay() }),
          configuration: .init(map: ["audioPolicy": "appManaged"]),
          textureOwner: .init(output: output, onFrame: { _ in }), avPlayer: player, emit: { _, _ in })
        defer { coordinator.dispose() }
        func load(_ source: YlAppleSourceDescriptor, _ id: String) async throws {
          try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            coordinator.load(.init(source: source), identity: .init(sessionId: id, loadRequestId: id),
              willCommit: { _ in }, didCommit: {}, didRollback: {}, completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
          }
        }
        var source = YlAppleSourceDescriptor(uri: server.url("/master.m3u8").absoluteString, kind: .network,
          formatHint: .hls, headers: ["X-Client": "ordinary"], loadOptions: .init(videoConstraints: original))
        try await load(source, "accepted")
        let oldItem = try XCTUnwrap(player.currentItem)
        XCTAssertEqual(oldItem.preferredMaximumResolution.width, 320)
        if restoring { coordinator.deactivate() }
        source.loadOptions = nil
        let pending = Task {
          if restoring {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
              coordinator.beginActivation(forcePlay: false, willCommit: { _ in }, didCommit: {}, didRollback: {},
                completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
            }
          } else { try await load(source, "new-load") }
        }
        await fulfillment(of: [held], timeout: 3)
        XCTAssertNoThrow(try coordinator.executeSynchronous(.constraints(changed)))
        XCTAssertEqual(coordinator.acceptedVideoConstraints, changed)
        release.signal(); try await pending.value
        let expected = restoring ? changed : original
        XCTAssertEqual(coordinator.acceptedVideoConstraints, expected)
        XCTAssertEqual(player.currentItem?.preferredMaximumResolution.width, expected.maxWidth.map(CGFloat.init) ?? 0)
        XCTAssertFalse(player.currentItem === oldItem)
        XCTAssertEqual(coordinator.identity?.sessionId, restoring ? "accepted" : "new-load")
      }
    }
  }

  func testProxyBoundarySnapshotTracksRealRequestAndCancellationWithoutResourceIdentity() throws {
    let server = try DashHTTPServer()
    defer { server.close() }
    server.handler = { _ in (200, [:], Data([1, 2, 3, 4])) }
    let proxy = try YlHlsMediaProxy(originURL: server.url("/private?token=secret"),
      headers: ["Authorization": "secret"], configuration: .init(map: [:]))
    defer { proxy.cancelAll() }
    XCTAssertEqual(proxy.diagnosticSnapshot["admittedRequests"], 0)
    let done = expectation(description: "real proxied bytes")
    URLSession.shared.dataTask(with: try proxy.proxyURL(for: server.url("/private?token=secret"))) { body, _, error in
      XCTAssertNil(error); XCTAssertEqual(body, Data([1, 2, 3, 4])); done.fulfill()
    }.resume()
    wait(for: [done], timeout: 4)
    let deadline = Date().addingTimeInterval(2)
    while (proxy.diagnosticSnapshot["activeTasks"] != 0 || proxy.diagnosticSnapshot["upstreamCompletions"] != 1) && Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    let snapshot = proxy.diagnosticSnapshot
    XCTAssertEqual(snapshot["acceptedConnections"], 1)
    XCTAssertEqual(snapshot["admittedRequests"], 1)
    XCTAssertEqual(snapshot["upstreamCompletions"], 1)
    XCTAssertEqual(snapshot["receivedBodyBytes"], 4)
    XCTAssertEqual(snapshot["activeTasks"], 0)
    XCTAssertEqual(snapshot["pendingSends"], 0)
    XCTAssertGreaterThan(snapshot["lastAdmissionUptime"] ?? 0, 0)
    XCTAssertTrue(snapshot.keys.allSatisfy { !$0.contains("secret") && !$0.contains("private") })
    proxy.cancelAll()
    XCTAssertEqual(proxy.diagnosticSnapshot["activeConnections"], 0)
    XCTAssertEqual(proxy.diagnosticSnapshot["cancelled"], 1)
    XCTAssertEqual(proxy.diagnosticSnapshot["admittedRequests"], 1)
  }

  func testProxyCancellationCannotInvalidateSessionDuringTaskAdmission() throws {
    let entered = expectation(description: "proxy reached URLSession task creation")
    let session = AdmissionRecordingSession(entered: entered)
    let proxy = try YlHlsMediaProxy(originURL: origin, headers: [:], configuration: .init(map: [:]), sessionFactory: { _, _, _ in session })
    defer { proxy.cancelAll() }
    let finished = expectation(description: "local connection closed")
    let url = try proxy.proxyURL(for: origin.deletingLastPathComponent().appendingPathComponent("segment.m4s"))
    URLSession.shared.dataTask(with: url) { _, _, _ in finished.fulfill() }.resume()
    wait(for: [entered], timeout: 3)
    let cancelled = expectation(description: "proxy cancellation finished")
    DispatchQueue.global().async {
      session.requestCancellation()
      proxy.cancelAll()
      cancelled.fulfill()
    }
    XCTAssertEqual(session.cancellationRequested.wait(timeout: .now() + 2), .success)
    // If invalidation can pass the in-flight admission, observe it before
    // releasing creation. Fixed code excludes it with the lifecycle lock.
    _ = session.invalidated.wait(timeout: .now() + 0.15)
    session.releaseCreation.signal()
    wait(for: [cancelled, finished], timeout: 3)
    XCTAssertEqual(session.events, ["create.enter", "cancel.request", "create.return", "resume", "invalidate", "cancel"])
    XCTAssertThrowsError(try proxy.proxyURL(for: origin))
  }

  func testLoaderCancellationCannotInvalidateSessionDuringTaskAdmission() throws {
    let entered = expectation(description: "loader reached URLSession task creation")
    let session = AdmissionRecordingSession(entered: entered)
    let loader = try YlHlsResourceLoader(originURL: origin, headers: [:], configuration: .init(map: [:]), sessionFactory: { _, _, _ in session })
    defer { loader.cancelAll() }
    let request = DashLoadingRequest(try loader.encodedAssetURL())
    let started = expectation(description: "startLoading returned")
    DispatchQueue.global().async { loader.startLoading(request); started.fulfill() }
    wait(for: [entered], timeout: 3)
    let cancelled = expectation(description: "loader cancellation finished")
    DispatchQueue.global().async {
      session.requestCancellation()
      loader.cancelAll()
      cancelled.fulfill()
    }
    XCTAssertEqual(session.cancellationRequested.wait(timeout: .now() + 2), .success)
    _ = session.invalidated.wait(timeout: .now() + 0.15)
    session.releaseCreation.signal()
    wait(for: [cancelled, started], timeout: 3)
    // Loader explicitly cancels its published task before session invalidation.
    XCTAssertEqual(session.events, ["create.enter", "cancel.request", "create.return", "resume", "cancel", "invalidate", "cancel"])
    XCTAssertEqual(request.finishCount, 1)
    XCTAssertEqual(request.error?.code, "network.cancelled")
  }

  func testPreflightCreatesPrivateMasterAndProxiesAllMediaWithoutCredentials() throws {
    let data = mpd
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data, headers: ["Content-Type": "application/octet-stream"]) })
    defer { prepared.discard() }
    XCTAssertNotEqual(try YlHlsURLCodec.decode(prepared.asset.url), origin)
    let master = read(prepared.loader, prepared.asset.url)
    XCTAssertNil(master.error)
    XCTAssertEqual(master.contentLength, Int64(master.received.count))
    XCTAssertEqual(master.contentType, "com.apple.m3u-playlist")
    XCTAssertTrue(master.rangeSupported)
    let video = read(prepared.loader, try child(master.received))
    let text = try XCTUnwrap(String(data: video.received, encoding: .utf8))
    XCTAssertEqual(text.components(separatedBy: "http://127.0.0.1:").count - 1, 3)
    XCTAssertFalse(text.contains("origin.test")); XCTAssertTrue(text.contains("#EXT-X-ENDLIST"))
    XCTAssertEqual(DashLoaderProtocol.captured.count, 1)
    XCTAssertEqual(DashLoaderProtocol.captured.first?.url, origin)
  }

  func testRegistryMissAndWrongKindNeverReachNetworkOrRedirect() throws {
    let data = mpd
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    defer { prepared.discard() }
    let plain = try YlHlsURLCodec.decode(prepared.asset.url)
    for url in [try YlHlsURLCodec.encode(plain.appendingPathComponent("missing"), kind: .manifest), try YlHlsURLCodec.encode(plain, kind: .media), try YlHlsURLCodec.encode(origin, kind: .manifest), try YlHlsURLCodec.encode(plain, kind: .key)] {
      let request = read(prepared.loader, url)
      XCTAssertEqual(request.error?.code, "container.hls_url_invalid")
      XCTAssertNil(request.redirectRequest); XCTAssertTrue(request.received.isEmpty)
    }
    XCTAssertEqual(DashLoaderProtocol.captured.count, 1)
  }

  func testVirtualManifestRangesClampHugeLengthAndUseCurrentOffset() throws {
    let data = mpd
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) })
    defer { prepared.discard() }
    let full = read(prepared.loader, prepared.asset.url).received
    for (offset, length) in [(4, 5), (7, Int.max), (full.count + 9, 5)] {
      let request = DashLoadingRequest(prepared.asset.url)
      request.requestedOffset = 2; request.currentOffset = Int64(offset); request.requestedLength = length; request.requestsAllDataToEnd = false
      prepared.loader.startLoading(request)
      let expected = Data(full.dropFirst(min(offset, full.count)).prefix(length))
      XCTAssertEqual(request.received, expected); XCTAssertNil(request.error)
      XCTAssertEqual(request.contentLength, Int64(full.count)); XCTAssertEqual(request.finishCount, 1)
    }
    XCTAssertEqual(DashLoaderProtocol.captured.count, 1)
  }

  func testCandidateDiscardDoesNotCancelTransferredSessionAndNamespacesDiffer() throws {
    let data = mpd
    let config = DashLoaderProtocol.configuration { $0.respond(data) }
    let active = try prepare(config)
    let retained = try active.takeLoader()
    defer { retained.cancelAll() }
    let candidate = try prepare(config)
    XCTAssertNotEqual(active.asset.url, candidate.asset.url)
    candidate.discard(); active.discard()
    XCTAssertEqual(read(candidate.loader, candidate.asset.url).error?.code, "network.cancelled")
    XCTAssertNil(read(retained, active.asset.url).error)
    XCTAssertThrowsError(try active.takeLoader())
    retained.cancelAll()
    XCTAssertEqual(read(retained, active.asset.url).error?.code, "network.cancelled")
  }

  func testRoot403IsSafeAndMalformedOrOversizedMPDFailBeforeAsset() throws {
    for scenario in ["403", "invalid", "declared-limit", "stream-limit"] {
      let config = DashLoaderProtocol.configuration { source in
        switch scenario {
        case "403": source.respond(Data("secret signed-url".utf8), status: 403)
        case "declared-limit": source.respond(Data(), headers: ["Content-Length": String(2 * 1024 * 1024 + 1)])
        case "stream-limit": source.respond(Data(repeating: 32, count: 2 * 1024 * 1024 + 1))
        default: source.respond(Data("<MPD>secret signed-url".utf8))
        }
      }
      XCTAssertThrowsError(try prepare(config)) { error in
        let native = error as? NativePlayerError
        XCTAssertEqual(native?.code, scenario == "403" ? "network.http_forbidden" : scenario.contains("limit") ? "resource.dash_manifest_too_large" : "container.dash_manifest_invalid")
        XCTAssertFalse(String(describing: native).contains("secret"))
        XCTAssertFalse(String(describing: native).contains("signed-url"))
        let published = YlAppleSafeDiagnostics.failure(error, scope: .command)
        XCTAssertEqual(published.code, native?.code)
        XCTAssertFalse(published.retryable)
        XCTAssertFalse(published.message.contains("secret"))
        XCTAssertFalse(published.message.contains("signed-url"))
        if scenario.contains("limit") { XCTAssertTrue(published.message.contains("2 MiB")) }
      }
    }
  }

  func testPreflightCancellationUnblocksAndCannotPublishLateAsset() {
    let started = expectation(description: "MPD request")
    let complete = expectation(description: "cancelled preparation")
    let token = YlOpenCancellationToken()
    let config = DashLoaderProtocol.configuration { _ in started.fulfill() }
    DispatchQueue.global().async {
      do { _ = try self.prepare(config, token: token); XCTFail("Cancelled preflight must fail") }
      catch { XCTAssertEqual((error as? NativePlayerError)?.code, "network.cancelled") }
      complete.fulfill()
    }
    wait(for: [started], timeout: 2)
    token.cancel()
    wait(for: [complete], timeout: 2)
    XCTAssertEqual(DashLoaderProtocol.captured.count, 1)
  }

  func testRecreatedLoaderRetainsStrippingWithoutStrippingSyntheticOrigin() throws {
    let data = mpd
    let context = YlHlsCredentialContext()
    context.strip(origin.absoluteString)
    context.strip("https://origin.test/root/init.mp4")
    let prepared = try prepare(DashLoaderProtocol.configuration { source in
      XCTAssertNil(source.request.value(forHTTPHeaderField: "Authorization"))
      XCTAssertEqual(source.request.value(forHTTPHeaderField: "X-Client"), "ordinary")
      source.respond(data)
    }, context: context, headers: ["Authorization": "secret", "X-Client": "ordinary"])
    defer { prepared.discard() }
    let master = read(prepared.loader, prepared.asset.url)
    let video = read(prepared.loader, try child(master.received))
    XCTAssertEqual(String(decoding: video.received, as: UTF8.self).components(separatedBy: "credentialsStripped=1").count - 1, 3)
    XCTAssertTrue(context.isStripped("https://origin.test/root/seg-2.m4s"))
    XCTAssertFalse(context.isStripped(try YlHlsURLCodec.decode(prepared.asset.url).absoluteString))
  }

  func testLargeExpandedRegistryFailsAndReleasesLoaderRetention() throws {
    let ledger = YlManagedBufferLedger()
    // Small MPD expands to a playlist well beyond the 2 MiB/4 MiB registry
    // bounds once every real resource has a loopback proxy address.
    let data = Data(String(decoding: mpd, as: UTF8.self).replacingOccurrences(of: "PT4S", with: "PT100000S").replacingOccurrences(of: "duration=\"2\"", with: "duration=\"1\"").utf8)
    try autoreleasepool {
      XCTAssertThrowsError(try prepare(DashLoaderProtocol.configuration { $0.respond(data) }, readTimeoutMs: 15_000, retention: ledger.acquireOpaqueHlsRetention())) { error in
        XCTAssertEqual((error as? NativePlayerError)?.code, "container.unsupported")
      }
    }
    let deadline = Date().addingTimeInterval(3)
    var scope: YlManagedBufferScope?
    while scope == nil && Date() < deadline {
      scope = try? ledger.makeScope(maxBytes: 1024)
      if scope == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    }
    XCTAssertNotNil(scope, "Failed compilation must release its opaque retention")
  }

  func testDiscardReleasesPrivateRegistryLoaderAndOpaqueRetention() throws {
    let data = mpd
    let ledger = YlManagedBufferLedger()
    weak var loader: YlHlsResourceLoader?
    try autoreleasepool {
      let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) }, retention: ledger.acquireOpaqueHlsRetention())
      loader = prepared.loader
      XCTAssertThrowsError(try ledger.makeScope(maxBytes: 1024))
      prepared.discard()
    }
    let deadline = Date().addingTimeInterval(3)
    while loader != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    XCTAssertNil(loader)
    XCTAssertNoThrow(try ledger.makeScope(maxBytes: 1024))
  }

  @MainActor func testPublicLoadCredentialHistorySurvivesRollbackAndResetsOnlyOnCommit() async throws {
    let server = try DashHTTPServer(), other = try DashHTTPServer(), data = mpd
    defer { server.close(); other.close() }
    server.handler = { request in
      if request.path == "/movie.mpd" { return (200,[:],data) }
      if request.path == "/bad.mpd" { return (200,[:],Data("<MPD type=\"dynamic\"/>".utf8)) }
      if request.path == "/seg-1.m4s" && request.headers["range"] == "bytes=1-2" { return (302,["Location":other.url("/hop").absoluteString],Data()) }
      return (200,[:],Data([1,2,3]))
    }
    other.handler = { _ in (302,["Location":server.url("/returned").absoluteString],Data()) }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    func request(_ id:String,_ token:String,_ path:String = "/movie.mpd") -> AppleLoadRequest {
      var request = AppleHostFixture.request(id,url:server.url(path).absoluteString,format:.dash)
      request.source.request = .init(headers:["X-Client":"ordinary"],credentials:["Authorization":token,"Cookie":token,"X-Session":token])
      return request
    }
    func loader() throws -> YlHlsResourceLoader {
      try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    }
    func segment(_ loader:YlHlsResourceLoader) throws -> URL {
      let root = read(loader,try loader.encodedAssetURL())
      let video = read(loader,try child(root.received))
      return try XCTUnwrap(String(decoding:video.received,as:UTF8.self).split(separator:"\n").first { $0.hasPrefix("http:") }.flatMap { URL(string:String($0)) })
    }
    func fetch(_ url:URL) async throws -> URLResponse {
      // Distinguish the controlled redirect from AVPlayer's own read-ahead.
      var request = URLRequest(url:url); request.setValue("bytes=1-2",forHTTPHeaderField:"Range")
      return try await URLSession.shared.data(for:request).1
    }
    let first = try await fixture.host.load(request:request("first","first-fixture"))
    let oldItem = try XCTUnwrap(fixture.av.currentItem), oldLoader = try loader()
    let oldURL = try segment(oldLoader)
    let response = try await fetch(oldURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
    XCTAssertTrue(oldLoader.credentialContext.isStripped(server.url("/seg-1.m4s").absoluteString))
    let oldRevision = oldLoader.credentialContext.revision
    do { _ = try await fixture.host.load(request:request("failed","failed-fixture","/bad.mpd")); XCTFail("Malformed candidate committed") }
    catch let error as PigeonError { XCTAssertEqual(error.code,"container.dash_dynamic_unsupported") }
    XCTAssertEqual(fixture.host.sessionId,first.sessionId); XCTAssertTrue(fixture.av.currentItem === oldItem)
    XCTAssertTrue(try loader() === oldLoader)
    _ = try await fetch(oldURL)
    let afterRollback = try XCTUnwrap(server.requests.last { $0.path == "/seg-1.m4s" && $0.headers["range"] == "bytes=1-2" })
    XCTAssertNil(afterRollback.headers["authorization"]); XCTAssertNil(afterRollback.headers["cookie"])
    XCTAssertNil(afterRollback.headers["x-session"]); XCTAssertEqual(afterRollback.headers["x-client"],"ordinary")
    let second = try await fixture.host.load(request:request("second","second-fixture"))
    let newLoader = try loader()
    XCTAssertNotEqual(first.sessionId,second.sessionId)
    XCTAssertFalse(newLoader.credentialContext === oldLoader.credentialContext)
    XCTAssertEqual(newLoader.credentialContext.revision,0)
    _ = try await fetch(segment(newLoader))
    let afterCommit = try XCTUnwrap(server.requests.last { $0.path == "/seg-1.m4s" && $0.headers["range"] == "bytes=1-2" })
    XCTAssertEqual(afterCommit.headers["authorization"],"second-fixture")
    XCTAssertEqual(afterCommit.headers["cookie"],"second-fixture"); XCTAssertEqual(afterCommit.headers["x-session"],"second-fixture")
    XCTAssertEqual(oldLoader.credentialContext.revision,oldRevision)
    XCTAssertEqual(oldLoader.diagnosticProxySnapshot["cancelled"],1)
    for r in other.requests + server.requests.filter({ $0.path == "/returned" }) {
      XCTAssertNil(r.headers["authorization"]); XCTAssertNil(r.headers["cookie"]); XCTAssertNil(r.headers["x-session"])
    }
  }

  @MainActor func testCommittedMediaFailureRetainsCredentialHistoryThroughRestorationAndFreshLoad() async throws {
    let server = try DashHTTPServer(), other = try DashHTTPServer(), data = mpd
    defer { server.close(); other.close() }
    server.handler = { request in
      if request.path == "/movie.mpd" { return (200,["Content-Type":"application/dash+xml"],data) }
      if request.path == "/init.mp4" { return (302,["Location":other.url("/hop").absoluteString],Data()) }
      return (410,["Content-Type":"video/mp4"],Data())
    }
    other.handler = { _ in (302,["Location":server.url("/gone.mp4").absoluteString],Data()) }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    try fixture.host.attach()
    func request(_ id:String,_ secret:String) -> AppleLoadRequest {
      var value = AppleHostFixture.request(id,url:server.url("/movie.mpd").absoluteString,format:.dash)
      value.source.request = .init(headers:["X-Client":"ordinary","X-Fixture-Load":id],credentials:["Authorization":secret,"Cookie":secret,"X-Session":secret])
      return value
    }
    func loader() throws -> YlHlsResourceLoader {
      try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    }
    func initURL(_ loader:YlHlsResourceLoader) throws -> URL {
      let root = read(loader,try loader.encodedAssetURL()), video = read(loader,try child(root.received))
      let line = try XCTUnwrap(String(decoding:video.received,as:UTF8.self).split(separator:"\n").first { $0.hasPrefix("#EXT-X-MAP:") })
      return try XCTUnwrap(line.split(separator:"\"").dropFirst().first.flatMap { URL(string:String($0)) })
    }
    // A successful Load reply acknowledges installation, not asynchronous media readiness.
    let accepted = try await fixture.host.load(request:request("failing","first-fixture"))
    let failedItem = try XCTUnwrap(fixture.av.currentItem), failedLoader = try loader()
    try await AppleHostCharacterizations.waitFor({ failedItem.status == .failed && fixture.callbacks.failures.contains { $0.sessionId == accepted.sessionId } },timeout:5)
    XCTAssertEqual(fixture.host.sessionId,accepted.sessionId)
    XCTAssertTrue(fixture.av.currentItem === failedItem)
    XCTAssertTrue(failedLoader.credentialContext.isStripped(server.url("/init.mp4").absoluteString))
    let failure = try XCTUnwrap(fixture.callbacks.failures.first { $0.sessionId == accepted.sessionId })
    XCTAssertEqual(failure.sessionId,accepted.sessionId)
    let revision = failedLoader.credentialContext.revision
    fixture.host.suspend(); fixture.host.resume()
    try await AppleHostCharacterizations.waitFor { fixture.av.currentItem != nil && fixture.av.currentItem !== failedItem }
    let restored = try loader()
    XCTAssertEqual(fixture.host.sessionId,accepted.sessionId)
    XCTAssertTrue(restored.credentialContext === failedLoader.credentialContext)
    // Distinguish this evidence request from AVPlayer read-ahead and retries.
    var probe = URLRequest(url:try initURL(restored)); probe.setValue("bytes=1-2",forHTTPHeaderField:"Range")
    let (_,response) = try await URLSession.shared.data(for:probe)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,410)
    let retried = try XCTUnwrap(server.requests.last { $0.path == "/init.mp4" && $0.headers["range"] == "bytes=1-2" })
    for key in ["authorization","cookie","x-session"] { XCTAssertNil(retried.headers[key]) }
    XCTAssertEqual(retried.headers["x-client"],"ordinary")
    XCTAssertEqual(restored.credentialContext.revision,revision)
    let fresh = try await fixture.host.load(request:request("fresh","second-fixture"))
    let freshLoader = try loader()
    XCTAssertNotEqual(fresh.sessionId,accepted.sessionId)
    XCTAssertFalse(freshLoader.credentialContext === failedLoader.credentialContext)
    try await AppleHostCharacterizations.waitFor { server.requests.contains { $0.path == "/init.mp4" && $0.headers["authorization"] == "second-fixture" } }
    let sent = try XCTUnwrap(server.requests.first { $0.path == "/init.mp4" && $0.headers["authorization"] == "second-fixture" })
    XCTAssertEqual(sent.headers["cookie"],"second-fixture"); XCTAssertEqual(sent.headers["x-session"],"second-fixture")
    // Complete this loader's init chain even if AVPlayer cancels read-ahead
    // after another media request fails. The loader remains owned by this Load.
    var freshProbe = URLRequest(url:try initURL(freshLoader)); freshProbe.setValue("bytes=2-3",forHTTPHeaderField:"Range")
    let (_,freshResponse) = try await URLSession.shared.data(for:freshProbe)
    XCTAssertEqual((freshResponse as? HTTPURLResponse)?.statusCode,410)
    try await AppleHostCharacterizations.waitFor({ server.requests.contains { $0.path == "/gone.mp4" && $0.headers["x-fixture-load"] == "fresh" } },timeout:5)
    for marker in ["failing","fresh"] {
      XCTAssertTrue(other.requests.contains { $0.path == "/hop" && $0.headers["x-fixture-load"] == marker })
      XCTAssertTrue(server.requests.contains { $0.path == "/gone.mp4" && $0.headers["x-fixture-load"] == marker })
    }
    XCTAssertThrowsError(try fixture.host.pause(command:.init(sessionId:accepted.sessionId)))
    XCTAssertEqual(failedLoader.diagnosticProxySnapshot["cancelled"],1)
    XCTAssertEqual(restored.diagnosticProxySnapshot["cancelled"],1)
    XCTAssertEqual(failedLoader.credentialContext.revision,revision)
    for r in other.requests + server.requests.filter({ $0.path == "/gone.mp4" }) {
      for key in ["authorization","cookie","x-session"] { XCTAssertNil(r.headers[key]) }
    }
  }

  @MainActor func testHeldBodyServerHandlesSplitHeadersAndContinuesUntilPeerEOF() async throws {
    let server = try DashHeldBodyServer(manifest:mpd,body:Data(repeating:1,count:128),redirect:URL(string:"http://127.0.0.1:1/revoke")!)
    defer { server.close() }
    let connection = NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:UInt16(server.url("/").port!))!,using:.tcp)
    defer { connection.cancel() }
    let ready = expectation(description:"client ready"), received = expectation(description:"partial response")
    let headerComplete = AbrPrerollCompletion()
    connection.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
    connection.start(queue:DispatchQueue.global()); await fulfillment(of:[ready],timeout:2)
    connection.receive(minimumIncompleteLength:1,maximumLength:4096) { data,_,_,error in
      XCTAssertNil(error); XCTAssertNotNil(data)
      XCTAssertEqual(headerComplete.result,true,"Server must not dispatch an incomplete request header")
      received.fulfill()
    }
    connection.send(content:Data("GET /ini".utf8),completion:.contentProcessed { _ in })
    try await Task.sleep(nanoseconds:100_000_000)
    headerComplete.finish(true)
    connection.send(content:Data("t.mp4 HTTP/1.1\r\nHost: owned\r\nX-Fixture-Hold: 1\r\n\r\n".utf8),completion:.contentProcessed { _ in })
    await fulfillment(of:[received],timeout:2)
    connection.send(content:Data("trailing-client-bytes".utf8),completion:.contentProcessed { _ in })
    try await Task.sleep(nanoseconds:100_000_000)
    connection.cancel()
    try await AppleHostCharacterizations.waitFor({ server.peerClosed==1 },timeout:2)
    XCTAssertEqual(server.heldCount,1)
  }

  @MainActor func testSameDashCandidateRevocationCancelsPartiallyReceivedUpstream() async throws {
    let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
    let app = try XCTUnwrap(Bundle(url:frameworks.appendingPathComponent("App.framework")))
    let media = try XCTUnwrap(app.resourceURL).appendingPathComponent("flutter_assets/assets/test_media/dash_timeline/avc/init-0.m4s")
    let other = try DashHTTPServer(); other.handler = { _ in (200,[:],Data([1,2,3])) }
    let segmentBytes = try Data(contentsOf:media.deletingLastPathComponent().appendingPathComponent("chunk-0-00001.m4s"))
    let initBytes = try Data(contentsOf:media)
    let server = try DashHeldBodyServer(manifest:mpd,body:initBytes,redirect:other.url("/revoked"),
      normalBodies:["/init.mp4":initBytes,"/seg-1.m4s":segmentBytes,"/seg-2.m4s":segmentBytes])
    defer { server.close(); other.close() }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    var request = AppleHostFixture.request("committed",url:server.url("/movie.mpd").absoluteString,format:.dash)
    request.source.request = .init(headers:[:],credentials:["Authorization":"fixture"])
    let accepted = try await fixture.host.load(request:request)
    let acceptedItem = try XCTUnwrap(fixture.av.currentItem)
    let active = try XCTUnwrap((acceptedItem.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    let context = active.credentialContext
    // Fixture-only header stalls candidate traffic, never the committed item's traffic.
    let candidate = try AbrDiagnosticCandidatePreparation.prepareReplacement(originURL:server.url("/movie.mpd"),headers:["X-Fixture-Hold":"1"],credentials:["Authorization":"fixture"],credentialContext:context)
    defer { candidate.discard() }
    let control = try YlHlsMediaProxy(originURL:server.url("/movie.mpd"),headers:[:],credentials:["Authorization":"fixture"],configuration:.init(map:[:]),credentialContext:context)
    defer { control.cancelAll() }
    var policy = AbrDiagnosticRecoveryPolicy()
    func sample(_ time:Double,width:Int = 320) -> AbrDiagnosticRecoveryPolicy.Sample {
      .init(time:time,generation:0,allowed:true,width:width,position:time,remaining:120-time,bufferAhead:10,
        bytes:Int64(time*200_000),transfer:time,requests:Int(time*4),overdue:1,credentialRevision:context.revision)
    }
    for (t,w) in [(0.0,640),(1.0,320),(9.0,320),(17.0,320)] { _ = policy.observe(sample(t,width:w)) }
    let ticket = try XCTUnwrap(policy.observe(sample(17.5))), epoch = ProcessInfo.processInfo.systemUptime
    var observedPartial = false, redirected = false, cleanup = 0
    let revoke = Task { @MainActor in
      do {
        try await AppleHostCharacterizations.waitFor({
          candidate.loader.diagnosticProxySnapshot["receivedBodyBytes",default:0]>0 &&
          candidate.loader.diagnosticProxySnapshot["activeTasks",default:0]>0
        },timeout:1.5)
        let beforeRevoke = candidate.loader.diagnosticProxySnapshot
        observedPartial = beforeRevoke["receivedBodyBytes",default:0]>0 && beforeRevoke["activeTasks",default:0]>0
        let evidence = try JSONSerialization.data(withJSONObject:beforeRevoke,options:[.sortedKeys])
        let attachment = XCTAttachment(data:evidence,uniformTypeIdentifier:"public.json")
        attachment.name = "candidate-before-revocation"; attachment.lifetime = .keepAlways
        XCTContext.runActivity(named:"Actual candidate transfer before revocation") { $0.add(attachment) }
        guard observedPartial else { return }
        let (_,response) = try await URLSession.shared.data(from:control.proxyURL(for:server.url("/revoke")))
        redirected = (response as? HTTPURLResponse)?.statusCode == 200
      } catch { XCTFail("Owned candidate did not reach partial upstream transfer and redirect") }
    }
    defer { revoke.cancel() }
    let result = await AbrDiagnosticPreroll.prepare(candidate.asset,position:.zero,deadlineUptime:epoch+2,
      allowed:{ policy.authorizes(ticket,sample(17.5+ProcessInfo.processInfo.systemUptime-epoch)) },
      cancelPending:{ cleanup += 1; candidate.discard() })
    await revoke.value
    XCTAssertTrue(observedPartial); XCTAssertTrue(redirected)
    XCTAssertEqual(result.outcome,"cancelled"); XCTAssertTrue(result.detached); XCTAssertNil(result.item)
    XCTAssertEqual(cleanup,1); XCTAssertEqual(policy.attempts,1)
    try await AppleHostCharacterizations.waitFor({
      let snap = candidate.loader.diagnosticProxySnapshot
      return snap["activeTasks"]==0 && snap["activeConnections"]==0 && snap["pendingSends"]==0 &&
        snap["cancelledCompletions",default:0]>0 && snap["upstreamCompletions"]==snap["admittedRequests"] &&
        server.peerClosed>0 && server.peerClosed==server.heldCount
    },timeout:2)
    XCTAssertThrowsError(try candidate.takeLoader())
    XCTAssertEqual(fixture.host.sessionId,accepted.sessionId); XCTAssertTrue(fixture.av.currentItem === acceptedItem)
    let root = read(active,try active.encodedAssetURL()); XCTAssertNil(root.error)
    let video = read(active,try child(root.received))
    let segmentURL = try XCTUnwrap(String(decoding:video.received,as:UTF8.self).split(separator:"\n").first { $0.hasPrefix("http:") }.flatMap { URL(string:String($0)) })
    let (continued,response) = try await URLSession.shared.data(from:segmentURL)
    XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200); XCTAssertEqual(continued,segmentBytes)
    XCTAssertEqual(active.diagnosticProxySnapshot["cancelled"],0)
    XCTAssertFalse(policy.authorizes(ticket,sample(17.5+ProcessInfo.processInfo.systemUptime-epoch)))
    XCTAssertTrue(other.requests.allSatisfy { $0.headers["authorization"] == nil })
  }

  func testActualMPDRedirectCrossOriginReturnAndProxyRangesNeverRestoreCredentials() throws {
    let data = mpd
    let other = try DashHTTPServer()
    let server = try DashHTTPServer()
    defer { server.close(); other.close() }
    other.handler = { _ in (302, ["Location": server.url("/final/movie.mpd").absoluteString], Data()) }
    server.handler = { request in
      if request.path == "/root.mpd" { return (302, ["Location": other.url("/hop").absoluteString], Data()) }
      if request.path == "/final/movie.mpd" { return (200, [:], data) }
      if request.headers["range"] == "bytes=2-4" { return (206, ["Content-Range": "bytes 2-4/6"], Data([2, 3, 4])) }
      return (200, [:], Data([0, 1, 2, 3, 4, 5]))
    }
    let context = YlHlsCredentialContext()
    func prepareNetwork() throws -> YlPreparedHlsAsset {
      try YlPreparedHlsAsset(originURL: server.url("/root.mpd"), isDash: true,
        headers: ["Authorization": "secret", "Cookie": "secret", "X-Client": "ordinary"], credentials: ["X-Session": "private"],
        configuration: .init(map: [:]), cancellationToken: .init(), credentialContext: context)
    }
    let prepared = try prepareNetwork()
    defer { prepared.discard() }
    let master = read(prepared.loader, prepared.asset.url)
    let video = read(prepared.loader, try child(master.received))
    let text = String(decoding: video.received, as: UTF8.self)
    let mapLine = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("#EXT-X-MAP:") })
    let initURL = try XCTUnwrap(mapLine.split(separator: "\"").dropFirst().first.flatMap { URL(string: String($0)) })
    let mediaURL = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("http:") }.flatMap { URL(string: String($0)) })
    for url in [initURL, mediaURL] {
      let done = expectation(description: "proxied range")
      var request = URLRequest(url: url); request.setValue("bytes=2-4", forHTTPHeaderField: "Range")
      URLSession.shared.dataTask(with: request) { body, response, error in
        XCTAssertNil(error); XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(body, Data([2, 3, 4])); done.fulfill()
      }.resume()
      wait(for: [done], timeout: 4)
    }
    XCTAssertEqual(server.requests.first?.headers["authorization"], "secret")
    XCTAssertEqual(server.requests.first?.headers["x-session"], "private")
    let descendants = Array(server.requests.dropFirst()) + other.requests
    XCTAssertTrue(descendants.contains { $0.path == "/final/init.mp4" })
    XCTAssertTrue(descendants.contains { $0.path == "/final/seg-1.m4s" })
    for request in descendants {
      XCTAssertNil(request.headers["authorization"]); XCTAssertNil(request.headers["cookie"])
      XCTAssertNil(request.headers["x-session"]); XCTAssertEqual(request.headers["x-client"], "ordinary")
    }
    XCTAssertTrue(context.isStripped(server.url("/root.mpd").absoluteString))
    XCTAssertTrue(context.isStripped(server.url("/final/init.mp4").absoluteString))
    let restored = try prepareNetwork(); defer { restored.discard() }
    XCTAssertNil(server.requests.last { $0.path == "/root.mpd" }?.headers["authorization"])
    XCTAssertNotEqual(prepared.asset.url, restored.asset.url)
  }

  @MainActor
  func testInactiveBackendCannotRegainPlaybackIntentFromDelayedPlayerRate() throws {
    let player = ResidualRatePlayer()
    let backend = YlAvPlayerBackend(playerId: 94,
      services: .init(platform: .current, textureOutput: AppleTestTexture(),
        makeDisplayDriver: { AppleClockDisplay(onTick: $0) }),
      configuration: PlayerConfiguration(map: ["audioPolicy": "appManaged"]), player: player, emit: { _ in })
    defer { backend.dispose() }
    try backend.activate()
    player.rate = 1
    XCTAssertTrue(backend.playbackIntent)
    backend.deactivate()
    XCTAssertFalse(backend.isActive)
    XCTAssertEqual(player.rate, 1, "Models a late native rate observation after pause/deactivation")
    XCTAssertFalse(backend.playbackIntent, "An inactive backend cannot regain intent from retired native output")
  }

  @MainActor
  func testActiveDashPlayDoesNotRefetchOrCancelPendingCandidate() async throws {
    try await assertActivePlayPreservesPendingCandidate(format: .dash)
  }

  @MainActor
  func testActiveHeaderedHlsPlayDoesNotRefetchOrCancelPendingCandidate() async throws {
    try await assertActivePlayPreservesPendingCandidate(format: .hls)
  }

  @MainActor
  private func assertActivePlayPreservesPendingCandidate(format: AppleMediaFormat) async throws {
    let data = format == .dash ? mpd : Data("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)
    let goodPath = format == .dash ? "/good.mpd" : "/good.m3u8"
    let held = expectation(description: "malformed candidate response held")
    let release = DispatchSemaphore(value: 0); defer { release.signal() }
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { request in
      if request.path == goodPath { return (200, ["Content-Type": format == .dash ? "application/dash+xml" : "application/vnd.apple.mpegurl"], data) }
      if request.path == "/candidate.mpd" {
        held.fulfill(); _ = release.wait(timeout: .now() + 8)
        return (200, [:], Data("<MPD type=\"dynamic\"/>".utf8))
      }
      return (404, [:], Data())
    }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    var source = AppleHostFixture.request("accepted", url: server.url(goodPath).absoluteString, format: format)
    source.source.request = .init(headers: ["X-Client": "ordinary"], credentials: ["X-Session": "private"])
    let accepted = try await fixture.host.load(request: source)
    let item = try XCTUnwrap(fixture.av.currentItem)
    let asset = try XCTUnwrap(item.asset as? AVURLAsset)
    let originalLoader = try XCTUnwrap(asset.resourceLoader.delegate as? YlHlsResourceLoader)
    XCTAssertTrue(fixture.host.isActive)
    let pending = Task { try await fixture.host.load(request: AppleHostFixture.request("candidate", url: server.url("/candidate.mpd").absoluteString, format: .dash)) }
    await fulfillment(of: [held], timeout: 3)
    if format == .dash {
      do {
        try await fixture.host.setVideoConstraints(command: .init(sessionId: accepted.sessionId, constraints: .init(maxWidth: 640)))
        XCTFail("Pending Load has priority")
      } catch let error as PigeonError { XCTAssertEqual(error.code, "network.cancelled") }
      XCTAssertTrue(fixture.av.currentItem === item)
    }
    try fixture.host.pause(command: .init(sessionId: accepted.sessionId))
    try await fixture.host.play(command: .init(sessionId: accepted.sessionId))
    XCTAssertEqual(fixture.host.sessionId, accepted.sessionId)
    XCTAssertTrue(fixture.av.currentItem === item, "Active play must keep the accepted item")
    XCTAssertEqual(server.requests.filter { $0.path == goodPath }.count, 1, "Active play cannot refetch the accepted source")
    release.signal()
    do { _ = try await pending.value; XCTFail("Malformed candidate committed") }
    catch let error as PigeonError { XCTAssertEqual(error.code, "container.dash_dynamic_unsupported", "Accepted-session controls must not supersede a pending Load") }
    try fixture.host.pause(command: .init(sessionId: accepted.sessionId))
    try await fixture.host.play(command: .init(sessionId: accepted.sessionId))
    XCTAssertTrue(fixture.av.currentItem === item)
    XCTAssertEqual(server.requests.filter { $0.path == goodPath }.count, 1)
    fixture.host.suspend(); fixture.host.resume()
    try await AppleHostCharacterizations.waitFor { fixture.host.isActive && fixture.av.currentItem != nil && fixture.av.currentItem !== item }
    let restored = try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.resourceLoader.delegate as? YlHlsResourceLoader)
    XCTAssertFalse(originalLoader === restored)
    XCTAssertTrue(originalLoader.credentialContext === restored.credentialContext)
    XCTAssertEqual(server.requests.filter { $0.path == goodPath }.count, format == .dash ? 1 : 2, "DASH restores its accepted snapshot; HLS rebuilds its remote manifest")
    XCTAssertEqual(fixture.host.sessionId, accepted.sessionId)
  }

  @MainActor
  func testStopDuringMPDPreflightAllowsNewLoadAndIgnoresLateResponse() async throws {
    let data = mpd
    let held = expectation(description: "MPD response held")
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { request in
      if request.path == "/held.mpd" { held.fulfill(); _ = release.wait(timeout: .now() + 6) }
      let response = request.path == "/held.mpd" ? Data(String(data: data, encoding: .utf8)!
        .replacingOccurrences(of: "width=\"320\" height=\"180\"", with: "width=\"640\" height=\"360\"").utf8) : data
      return (200, [:], response)
    }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    try fixture.host.attach()
    let pending = Task { try await fixture.host.load(request: AppleHostFixture.request("held", url: server.url("/held.mpd").absoluteString, format: .dash)) }
    await fulfillment(of: [held], timeout: 3)
    try await fixture.host.stop()
    do { _ = try await pending.value; XCTFail("Stopped MPD committed") }
    catch let error as PigeonError { XCTAssertEqual(error.code, "network.cancelled") }
    XCTAssertNil(fixture.host.sessionId)
    await fixture.settle()
    XCTAssertEqual(fixture.callbacks.states.last?.videoTracks.count, 0)
    let fresh = try await fixture.host.load(request: AppleHostFixture.request("fresh", url: server.url("/fresh.mpd").absoluteString, format: .dash))
    let current = fixture.av.currentItem
    release.signal()
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(fixture.host.sessionId, fresh.sessionId)
    XCTAssertTrue(fixture.av.currentItem === current)
    await fixture.settle()
    XCTAssertEqual(fixture.callbacks.states.last?.videoTracks.map(\.id), ["dash-video-w320-h180-b1000"])
    XCTAssertFalse(fixture.callbacks.states.contains { $0.videoTracks.contains { $0.width == 640 } })
  }

  @MainActor
  func testCoordinatorKeepsDashSessionOnInvalidReplacementAndRebuildsPrivateAssetOnResume() async throws {
    let data = mpd
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { request in
      if request.path == "/good.mpd" { return (200, [:], data) }
      if request.path == "/bad.mpd" { return (200, [:], Data("<MPD type=\"dynamic\"/>".utf8)) }
      return (404, [:], Data())
    }
    let fixture = AppleHostFixture(); defer { fixture.host.close() }
    try fixture.host.attach()
    let accepted = try await fixture.host.load(request: AppleHostFixture.request("dash", url: server.url("/good.mpd").absoluteString, format: .dash))
    let expectedRevision0 = fixture.host.initialState.revision
    let expectedSession0 = fixture.host.initialState.sessionId
    try await AppleHostCharacterizations.waitFor {
      let state = fixture.callbacks.states.last
      let delta = fixture.callbacks.deltas.last
      let deliveredRevision = max(state?.revision ?? -1,
        delta?.sessionId == expectedSession0 ? delta?.revision ?? -1 : -1)
      return state?.sessionId == expectedSession0 && deliveredRevision >= expectedRevision0
    }
    XCTAssertEqual(fixture.callbacks.states.last?.videoTracks.map(\.id), ["dash-video-w320-h180-b1000"])
    let item = try XCTUnwrap(fixture.av.currentItem)
    let originalPrivateURL = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
    XCTAssertNotEqual(try YlHlsURLCodec.decode(originalPrivateURL), server.url("/good.mpd"))
    do { _ = try await fixture.host.load(request: AppleHostFixture.request("bad", url: server.url("/bad.mpd").absoluteString, format: .dash)); XCTFail("Invalid DASH committed") }
    catch let error as PigeonError { XCTAssertEqual(error.code, "container.dash_dynamic_unsupported") }
    XCTAssertEqual(fixture.host.sessionId, accepted.sessionId)
    XCTAssertTrue(fixture.av.currentItem === item)
    let expectedRevision1 = fixture.host.initialState.revision
    let expectedSession1 = fixture.host.initialState.sessionId
    try await AppleHostCharacterizations.waitFor {
      let state = fixture.callbacks.states.last
      let delta = fixture.callbacks.deltas.last
      let deliveredRevision = max(state?.revision ?? -1,
        delta?.sessionId == expectedSession1 ? delta?.revision ?? -1 : -1)
      return state?.sessionId == expectedSession1 && deliveredRevision >= expectedRevision1
    }
    XCTAssertEqual(fixture.callbacks.states.last?.videoTracks.map(\.id), ["dash-video-w320-h180-b1000"])
    fixture.host.suspend(); fixture.host.resume()
    try await AppleHostCharacterizations.waitFor { fixture.av.currentItem != nil && fixture.av.currentItem !== item }
    let restoredURL = try XCTUnwrap((fixture.av.currentItem?.asset as? AVURLAsset)?.url)
    XCTAssertNotEqual(originalPrivateURL, restoredURL)
    XCTAssertEqual(try YlHlsURLCodec.resourceKind(restoredURL), .manifest)
    XCTAssertEqual(fixture.host.sessionId, accepted.sessionId)
    XCTAssertEqual(server.requests.filter { $0.path == "/good.mpd" }.count, 1)
    let expectedRevision2 = fixture.host.initialState.revision
    let expectedSession2 = fixture.host.initialState.sessionId
    try await AppleHostCharacterizations.waitFor {
      let state = fixture.callbacks.states.last
      let delta = fixture.callbacks.deltas.last
      let deliveredRevision = max(state?.revision ?? -1,
        delta?.sessionId == expectedSession2 ? delta?.revision ?? -1 : -1)
      return state?.sessionId == expectedSession2 && deliveredRevision >= expectedRevision2
    }
    XCTAssertEqual(fixture.callbacks.states.last?.videoTracks.map(\.id), ["dash-video-w320-h180-b1000"])
    try await fixture.host.stop()
    let expectedRevision3 = fixture.host.initialState.revision
    let expectedSession3 = fixture.host.initialState.sessionId
    try await AppleHostCharacterizations.waitFor {
      let state = fixture.callbacks.states.last
      let delta = fixture.callbacks.deltas.last
      let deliveredRevision = max(state?.revision ?? -1,
        delta?.sessionId == expectedSession3 ? delta?.revision ?? -1 : -1)
      return state?.sessionId == expectedSession3 && deliveredRevision >= expectedRevision3
    }
    XCTAssertEqual(fixture.callbacks.states.last?.videoTracks.count, 0)
    XCTAssertNil(fixture.av.currentItem); XCTAssertNil(fixture.host.sessionId)
  }

  func testCrossOriginBaseURLReturnSeedsStickyContext() throws {
    let data = Data("""
      <MPD type="static" mediaPresentationDuration="PT4S"><BaseURL>https://foreign.test/</BaseURL><Period><BaseURL>https://origin.test/returned/</BaseURL><AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1000" codecs="avc1.64001f" width="320" height="180"><SegmentTemplate initialization="init.mp4" media="seg-$Number$.m4s" duration="2"/></Representation></AdaptationSet></Period></MPD>
      """.utf8)
    let context = YlHlsCredentialContext()
    let prepared = try prepare(DashLoaderProtocol.configuration { $0.respond(data) }, context: context, headers: ["Authorization": "secret", "X-Client": "ordinary"])
    defer { prepared.discard() }
    XCTAssertTrue(context.isStripped("https://origin.test/returned/init.mp4"))
    XCTAssertTrue(context.isStripped("https://origin.test/returned/seg-1.m4s"))
    XCTAssertEqual(DashLoaderProtocol.captured.first?.value(forHTTPHeaderField: "Authorization"), "secret")
    XCTAssertEqual(DashLoaderProtocol.captured.first?.value(forHTTPHeaderField: "X-Client"), "ordinary")
    XCTAssertFalse(context.isStripped(try YlHlsURLCodec.decode(prepared.asset.url).absoluteString))
  }
}

private final class DashHTTPServer {
  struct Request { let path: String; let headers: [String: String] }
  typealias Response = (Int, [String: String], Data)
  private let listener: NWListener
  private let lock = NSLock()
  private var log: [Request] = []
  private var responseHandler: ((Request) -> Response)?
  var handler: ((Request) -> Response)? {
    get { lock.lock(); defer { lock.unlock() }; return responseHandler }
    set { lock.lock(); responseHandler = newValue; lock.unlock() }
  }
  var requests: [Request] { lock.lock(); defer { lock.unlock() }; return log }
  func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }
  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      connection.start(queue: DispatchQueue.global())
      connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
        guard let self, let data, !data.isEmpty else { connection.cancel(); return }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        let path = lines[0].split(separator: " ").dropFirst().first.map(String.init) ?? ""
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
          guard let colon = line.firstIndex(of: ":") else { continue }
          headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(path: path, headers: headers)
        self.lock.lock(); self.log.append(request); let handler = self.responseHandler; self.lock.unlock()
        let (status, extra, body) = handler?(request) ?? (404, [:], Data())
        var header = "HTTP/1.1 \(status) Response\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (key, value) in extra { header += "\(key): \(value)\r\n" }
        connection.send(content: Data((header + "\r\n").utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
      }
    }
    listener.start(queue: DispatchQueue(label: "yl.test.dash.http"))
    guard ready.wait(timeout: .now() + 3) == .success else { listener.cancel(); throw NSError(domain: "DashTestServer", code: 1) }
  }
  func close() { handler = nil; listener.cancel() }
  deinit { close() }
}

/// Records the URLSession admission/invalidation contract without triggering
/// Foundation's fatal Objective-C exception on the intentionally broken path.
private final class AdmissionRecordingSession: URLSession, @unchecked Sendable {
  let releaseCreation = DispatchSemaphore(value: 0)
  let cancellationRequested = DispatchSemaphore(value: 0)
  let invalidated = DispatchSemaphore(value: 0)
  private let entered: XCTestExpectation
  private let eventLock = NSLock()
  private var recorded: [String] = []
  private lazy var recordedTask = AdmissionRecordingTask { [weak self] in self?.record($0) }
  var events: [String] { eventLock.lock(); defer { eventLock.unlock() }; return recorded }
  init(entered: XCTestExpectation) { self.entered = entered; super.init() }
  private func record(_ event: String) { eventLock.lock(); recorded.append(event); eventLock.unlock() }
  func requestCancellation() { record("cancel.request"); cancellationRequested.signal() }
  override func dataTask(with request: URLRequest) -> URLSessionDataTask {
    record("create.enter"); entered.fulfill()
    if releaseCreation.wait(timeout: .now() + 4) != .success { record("gate.timeout") }
    record("create.return")
    return recordedTask
  }
  override func invalidateAndCancel() {
    record("invalidate"); recordedTask.cancel(); invalidated.signal()
  }
}

private final class AdmissionRecordingTask: URLSessionDataTask, @unchecked Sendable {
  private let record: (String) -> Void
  init(record: @escaping (String) -> Void) { self.record = record; super.init() }
  override var taskIdentifier: Int { 42 }
  override func resume() { record("resume") }
  override func cancel() { record("cancel") }
}

/// Native rate callbacks can lag the command that retired an item. Keep that
/// observation nonzero deterministically while exercising real backend state.
private final class ResidualRatePlayer: AVPlayer {
  private var observedRate: Float = 0
  override var rate: Float {
    get { observedRate }
    set { observedRate = newValue }
  }
  override func pause() {}
}

private final class DashPixelOutput: AVPlayerItemVideoOutput, @unchecked Sendable {
  let buffer: CVPixelBuffer
  var beforeCopy: (() -> Void)?
  var measuredItemTime = CMTime.zero
  override func itemTime(forHostTime hostTimeInSeconds: CFTimeInterval) -> CMTime { measuredItemTime }
  init(width: Int, height: Int) {
    var result: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
      nil, &result) == kCVReturnSuccess)
    buffer = result!
    super.init(pixelBufferAttributes: nil)
  }
  override func hasNewPixelBuffer(forItemTime itemTime: CMTime) -> Bool { true }
  override func copyPixelBuffer(forItemTime itemTime: CMTime, itemTimeForDisplay outItemTimeForDisplay: UnsafeMutablePointer<CMTime>?) -> CVPixelBuffer? { beforeCopy?(); return buffer }
}

// The decoder allocation boundary is controlled; source preparation, FFmpeg
// demux, fallback construction, backend retention, and Load commit stay real.
private final class DashPassiveVTFactory: YlVTSessionFactory {
  func makeSession(formatDescription: CMVideoFormatDescription,
    output: @escaping (YlVTDecodedImage) -> Void) throws -> YlVTSession { DashPassiveVTSession() }
}
private final class DashPassiveVTSession: YlVTSession {
  // Explicit simulated evidence keeps this allocation-boundary test independent of hardware.
  let hardwareEvidence = YlHardwareDecoderEvidence(mode: .hardware)
  let usesHardwareDecoder = true
  func decode(_ sample: CMSampleBuffer, generation: UInt64, reservation: YlVideoDecodeReservation?) -> OSStatus {
    reservation?.release(); return noErr
  }
  func flush() {}
  func invalidate() {}
}

private final class DashCatalogClockPlayer: AVPlayer {
  var measuredTime = CMTime.zero
  var resetClockOnReplacement = false
  var timelineDuration: CMTime?
  var timelineRanges: [NSValue] = []
  private var timelineItem: DashCatalogTimelineItem?
  override var currentItem: AVPlayerItem? { timelineItem ?? super.currentItem }
  override func replaceCurrentItem(with item: AVPlayerItem?) {
    if resetClockOnReplacement { measuredTime = .zero }
    timelineItem = item.flatMap { item in
      timelineDuration.map { DashCatalogTimelineItem(asset: item.asset, duration: $0, ranges: timelineRanges) }
    }
    super.replaceCurrentItem(with: item)
  }
  var tick: ((CMTime) -> Void)?
  var seekCompletion: ((Bool) -> Void)?
  var requestedSeek: CMTime?
  var landOnSeek = false
  override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) {
    requestedSeek = time
    if landOnSeek { measuredTime = time }
  }
  override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime, completionHandler: @escaping (Bool) -> Void) {
    requestedSeek = time
    if landOnSeek { measuredTime = time }
    seekCompletion = completionHandler
  }
  override func currentTime() -> CMTime { measuredTime }
  override func addPeriodicTimeObserver(forInterval interval: CMTime, queue: DispatchQueue?, using block: @escaping (CMTime) -> Void) -> Any {
    tick = block
    return NSObject()
  }
  override func removeTimeObserver(_ observer: Any) {}
}

private final class DashCatalogTimelineItem: AVPlayerItem, @unchecked Sendable {
  private let measuredDuration: CMTime
  private let measuredRanges: [NSValue]
  init(asset: AVAsset, duration: CMTime, ranges: [NSValue]) {
    measuredDuration = duration; measuredRanges = ranges
    super.init(asset: asset, automaticallyLoadedAssetKeys: nil)
  }
  override var duration: CMTime { measuredDuration }
  override var seekableTimeRanges: [NSValue] { measuredRanges }
}

final class YlDashProgramNativeTests: XCTestCase {
  func testExactProgramParserPreservesPTOAndOverlap() throws {
    let origin = URL(string: "https://origin.test/movie.mpd")!
    let xml = """
      <MPD mediaPresentationDuration="PT7S"><Period start="PT0S" duration="PT4S"><AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1000" width="320" height="180" codecs="avc1.42c01e"><SegmentTemplate initialization="init.mp4" media="$Time$.m4s" timescale="3" presentationTimeOffset="30"><SegmentTimeline><S t="30" d="3" r="3"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period><Period start="PT3S" duration="PT4S"><AdaptationSet mimeType="video/mp4"><Representation id="v" bandwidth="1000" width="320" height="180" codecs="avc1.42c01e"><SegmentTemplate initialization="init.mp4" media="$Number$.m4s" duration="1"/></Representation></AdaptationSet></Period></MPD>
      """
    let program = try YlDashProgramDocument.parse(Data(xml.utf8), source: origin, final: origin)
    XCTAssertEqual(try program.timeline.end(of: 0), try YlDashProgramTime(3))
    XCTAssertEqual(try program.timeline.map(sample: YlDashProgramTime(31, 3), offset: program.periods[0].tracks[0].offset, period: 0), try YlDashProgramTime(1, 3))
    XCTAssertEqual(program.timeline.duration, try YlDashProgramTime(7))
  }

  func testManagedTransportReadsExactRangeAndRetainsPayloadBudget() throws {
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { request in
      guard request.headers["range"] == "bytes=10-12", request.headers["authorization"] == "fixture" else { return (403, [:], Data()) }
      return (206, ["Content-Range": "bytes 10-12/100"], Data([4, 5, 6]))
    }
    let url = server.url("/sample"), ledger = YlManagedBufferLedger()
    let scope = try ledger.makeScope(maxBytes: 1024 * 1024)
    let reader = YlDashProgramResources(source: url, headers: [:], credentials: ["Authorization": "fixture"], configuration: .init(map: ["maxRetries": 0]), scope: scope)
    let resource = YlDashProgram.Resource(candidates: [.init(url: url, credentialsStripped: false)], range: .init(start: 10, length: 3))
    let payload = try reader.read(resource, maximumBytes: 4, cancellation: .init())
    XCTAssertEqual(payload.data, Data([4, 5, 6])); XCTAssertEqual(payload.resourceLength, 100)
    XCTAssertEqual(server.requests.count, 1)
  }

  func testManagedTransportRejectsWholeResponseToRangeWithoutRetry() throws {
    let server = try DashHTTPServer(); defer { server.close() }
    server.handler = { _ in (200, [:], Data([1, 2, 3])) }
    let url = server.url("/sample"), ledger = YlManagedBufferLedger()
    let scope = try ledger.makeScope(maxBytes: 1024 * 1024)
    let reader = YlDashProgramResources(source: url, headers: [:], credentials: [:], configuration: .init(map: ["maxRetries": 2]), scope: scope)
    let resource = YlDashProgram.Resource(candidates: [.init(url: url, credentialsStripped: false)], range: .init(start: 10, length: 3))
    for _ in 0..<2 {
      XCTAssertThrowsError(try reader.read(resource, maximumBytes: 4, cancellation: .init())) {
        XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.range_invalid")
      }
    }
    XCTAssertEqual(server.requests.count, 1)
  }
}

final class YlDashSampleSourceNativeTests: XCTestCase {
  private func source(_ name: String, kind: YlDashProgram.Track.Kind,
                      token: YlOpenCancellationToken = .init()) throws -> YlDashSampleSource {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4"))
    let bytes = try Data(contentsOf: url)
    let scope = try YlManagedBufferLedger(maxBytes: 4 * 1024 * 1024).makeScope(maxBytes: nil)
    return try YlDashSampleSource(initialization: .init(data: Data(), finalURL: url, credentialsStripped: false, resourceLength: nil, reservation: nil),
      fragment: .init(data: bytes, finalURL: url, credentialsStripped: false, resourceLength: nil, reservation: nil),
      kind: kind, cancellation: token, scope: scope)
  }
  func testVideoFragmentKeepsOriginalTenSecondTicksAndPacketOwnership() throws {
    var demux: YlDashSampleSource? = try source("p01-video-fragment", kind: .video)
    let packet = try XCTUnwrap(demux?.next())
    XCTAssertEqual(packet.pts, try YlDashProgramTime(10))
    XCTAssertEqual(packet.duration, try YlDashProgramTime(1, 24))
    let format = try XCTUnwrap(demux?.videoFormat)
    demux = nil
    let sample = try packet.videoSample(format: format, pts: CMTime(value: 1, timescale: 3), dts: .invalid, duration: CMTime(value: 1, timescale: 24))
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: 1, timescale: 3))
    XCTAssertGreaterThan(CMSampleBufferGetTotalSampleSize(sample), 0)
  }
  func testAudioFragmentKeepsTwentySecondOffsetAndNegativePriming() throws {
    let demux = try source("p01-audio-fragment", kind: .audio)
    let converter = YlAppleCompressedAudioConverter()
    try converter.configure(stream: .init(codec: .aac, sampleRate: 48000, channelCount: 1, magicCookie: demux.codecConfiguration, generation: 1))
    let window = try YlDashProgramTimeline.Window(start: YlDashProgramTime(0), end: YlDashProgramTime(47104, 48000))
    var packets = 0, frames = 0, positiveCrossings = 0, previous: Float = 0
    while let packet = try demux.next() {
      let pts = try packet.pts.subtracting(YlDashProgramTime(20))
      if packets == 0 { XCTAssertEqual(pts, try YlDashProgramTime(-1024, 48000)) }
      let input = try YlCompressedAudioPacket(data: packet.audioBytes(), ptsUs: pts.converted(to: 1_000_000, rounding: .floor), durationUs: packet.duration.converted(to: 1_000_000, rounding: .floor), generation: 1)
      if let buffer = try converter.convert(packet: input), let pcm = buffer.payload as? AVAudioPCMBuffer {
        let trim = try YlDashSampleWindow.pcmFrames(pts: pts, sampleRate: 48000, count: Int(pcm.frameLength), window: window)
        let channel = try XCTUnwrap(pcm.floatChannelData?[0])
        for index in trim.skip..<(trim.skip + trim.count) {
          let value = channel[index]
          if previous <= 0 && value > 0 { positiveCrossings += 1 }; previous = value
        }
        frames += trim.count
      }
      packets += 1
    }
    XCTAssertEqual(packets, 47); XCTAssertEqual(frames, 47104)
    XCTAssertEqual(Double(positiveCrossings) * 48000 / Double(frames), 440, accuracy: 4)
  }
  func testMappedVideoActuallyDecodesRedFrameAtProgramZero() throws {
    let demux = try source("p01-video-fragment", kind: .video)
    let packet = try XCTUnwrap(demux.next()), format = try XCTUnwrap(demux.videoFormat)
    let done = expectation(description: "decoded original fragment")
    let decoder = try YlVideoToolboxDecoder(formatDescription: format,
      factory: YlHardwareVTSessionFactory(policy: .systemDefault),
      outputPixelFormat: kCVPixelFormatType_32BGRA, onFrame: { frame in
        XCTAssertEqual(frame.ptsUs, 0)
        CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly) }
        if let base = CVPixelBufferGetBaseAddress(frame.pixelBuffer) {
          let offset = CVPixelBufferGetHeight(frame.pixelBuffer)/2 * CVPixelBufferGetBytesPerRow(frame.pixelBuffer) + CVPixelBufferGetWidth(frame.pixelBuffer)/2 * 4
          let pixel = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
          XCTAssertGreaterThan(pixel[2], 240); XCTAssertLessThan(pixel[1], 10); XCTAssertLessThan(pixel[0], 10)
        } else { XCTFail("missing actual decoded pixels") }
        done.fulfill()
      }, onError: { error in XCTFail(error.code + " " + (error.diagnostic ?? "no diagnostic")); done.fulfill() })
    defer { decoder.dispose() }
    let sample = try packet.videoSample(format: format, pts: .zero, dts: .zero, duration: CMTime(value: 1, timescale: 24))
    decoder.decode(sample: sample, generation: 1)
    decoder.drain()
    wait(for: [done], timeout: 3)
  }
  func testCancelledFragmentDoesNotYieldAnotherPacket() throws {
    let token = YlOpenCancellationToken()
    let demux = try source("p01-video-fragment", kind: .video, token: token)
    _ = try demux.next(); token.cancel()
    XCTAssertThrowsError(try demux.next()) { XCTAssertEqual(($0 as? NativePlayerError)?.code, "network.cancelled") }
  }
}

extension YlDashSampleSourceNativeTests {
  func testManagedProgramCursorLoadsIndependentPTOThroughActualTransport() throws {
    let server = try DashHTTPServer(); defer { server.close() }
    let video = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "p01-video-fragment", withExtension: "mp4")))
    let audio = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "p01-audio-fragment", withExtension: "mp4")))
    let mpd = Data("""
      <MPD mediaPresentationDuration="PT0.5S"><Period><AdaptationSet mimeType="video/mp4"><Representation id="v" codecs="avc1.42c01e" bandwidth="350000" width="320" height="180"><SegmentTemplate timescale="12288" presentationTimeOffset="122880" initialization="v-init" media="v-segment"><SegmentTimeline><S t="122880" d="12288"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet><AdaptationSet mimeType="audio/mp4"><Representation id="a" codecs="mp4a.40.2" bandwidth="64000" audioSamplingRate="48000"><SegmentTemplate timescale="48000" presentationTimeOffset="960000" initialization="a-init" media="a-segment"><SegmentTimeline><S t="960000" d="47104"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>
      """.utf8)
    func split(_ bytes: Data) -> Int {
      var offset = 0
      while offset + 8 <= bytes.count {
        let size = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
        if String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self) == "sidx" { return offset }
        if size < 8 { return 0 }; offset += size
      }
      return 0
    }
    let videoSplit = split(video), audioSplit = split(audio)
    XCTAssertGreaterThan(videoSplit, 0); XCTAssertGreaterThan(audioSplit, 0)
    server.handler = { request in
      guard request.headers["authorization"] == "owned" else { return (403, [:], Data()) }
      let bytes: Data
      switch request.path {
      case "/program.mpd": bytes = mpd
      case "/v-init": bytes = Data(video.prefix(videoSplit))
      case "/v-segment": bytes = Data(video.dropFirst(videoSplit))
      case "/a-init": bytes = Data(audio.prefix(audioSplit))
      case "/a-segment": bytes = Data(audio.dropFirst(audioSplit))
      default: return (404, [:], Data())
      }
      return (200, [:], bytes)
    }
    let url = server.url("/program.mpd"), token = YlOpenCancellationToken()
    let scope = try YlManagedBufferLedger(maxBytes: 32 * 1024 * 1024).makeScope(maxBytes: nil)
    let resources = YlDashProgramResources(source: url, headers: [:], credentials: ["Authorization": "owned"], configuration: .init(map: ["maxRetries": 0]), scope: scope)
    let program = try YlDashProgramLoader.load(url: url, resources: resources, cancellation: token)
    XCTAssertEqual(program.timeline.duration, try YlDashProgramTime(1, 2))
    for track in program.periods[0].tracks {
      let cursor = try YlDashTrackCursor(track: track, window: program.timeline.windows[0], position: YlDashProgramTime(0), resources: resources, cancellation: token, scope: scope)
      let first = try XCTUnwrap(cursor.next())
      XCTAssertEqual(first.pts, try YlDashProgramTime(track.kind == .video ? 0 : -1024, track.kind == .video ? 1 : 48000))
    }
    XCTAssertEqual(server.requests.count, 5)
  }
}

extension YlDashSampleSourceNativeTests {
  func testPCMClipPreservesSamplesAndAllocationAtFractionalBoundaries() throws {
    for interleaved in [false, true] {
      let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved))
      let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
      pcm.frameLength = 1024
      let list = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
      for channel in list {
        let samples = try XCTUnwrap(channel.mData).assumingMemoryBound(to: Float.self)
        for index in 0..<Int(channel.mDataByteSize)/4 { samples[index] = Float(index) }
      }
      let start = try YlDashProgramTime(167936, 48000)
      let window = try YlDashProgramTimeline.Window(start: start.adding(YlDashProgramTime(1, 96000)), end: YlDashProgramTime(7, 2))
      let source = YlScheduledAudioBuffer(payload: pcm, ptsUs: 0, durationUs: 0, byteCount: 8192, generation: 7)
      let clipped = try XCTUnwrap(YlDashPCMClipper.clip(source, pts: start, window: window))
      XCTAssertEqual(pcm.frameLength, 63); XCTAssertEqual(clipped.byteCount, 8192); XCTAssertEqual(clipped.generation, 7)
      XCTAssertEqual(try XCTUnwrap(pcm.floatChannelData?[0])[0], interleaved ? 2 : 1)
    }
  }
}

private final class DashProgramTexture: YlTextureOutput {
  let textureId: Int64 = 991
  var frames = 0, clears = 0
  var visible = false
  var rgb: [UInt8] = []
  private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
  func publish(_ pixelBuffer: CVPixelBuffer?) {
    guard let pixelBuffer else { return }
    frames += 1; visible = true
    var rgba = [UInt8](repeating: 0, count: 4)
    let image = CIImage(cvPixelBuffer: pixelBuffer)
    context.render(image, toBitmap: &rgba, rowBytes: 4,
      bounds: CGRect(x: image.extent.midX, y: image.extent.midY, width: 1, height: 1),
      format: .RGBA8, colorSpace: nil)
    rgb = Array(rgba.prefix(3))
  }
  func resize(width: Int, height: Int) {}
  func clear() { clears += 1; visible = false }
  func dispose() {}
}
private final class DashProgramDisplay: YlDisplayDriving {
  var isPaused = false
  let tick: () -> Void
  init(_ tick: @escaping () -> Void) { self.tick = tick }
  func invalidate() { isPaused = true }
  func fire() { if !isPaused { tick() } }
}

extension YlDashSampleSourceNativeTests {
  @MainActor func testProgramBackendPlaysAndClipsActualHalfSecond() async throws {
    let server = try DashHTTPServer(); defer { server.close() }
    let bundle = Bundle(for: Self.self)
    let video = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "p01-video-fragment", withExtension: "mp4")))
    let audio = try Data(contentsOf: XCTUnwrap(bundle.url(forResource: "p01-audio-fragment", withExtension: "mp4")))
    let xml = Data("""
      <MPD mediaPresentationDuration="PT0.5S"><Period duration="PT0.5S"><AdaptationSet mimeType="video/mp4"><Representation id="v" codecs="avc1.42c01e" bandwidth="350000" width="320" height="180"><SegmentTemplate timescale="12288" presentationTimeOffset="122880" initialization="vi" media="vs"><SegmentTimeline><S t="122880" d="12288"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet><AdaptationSet mimeType="audio/mp4"><Representation id="a" codecs="mp4a.40.2" bandwidth="64000" audioSamplingRate="48000"><SegmentTemplate timescale="48000" presentationTimeOffset="960000" initialization="ai" media="as"><SegmentTimeline><S t="960000" d="47104"/></SegmentTimeline></SegmentTemplate></Representation></AdaptationSet></Period></MPD>
      """.utf8)
    server.handler = { request in
      let data: Data
      switch request.path {
      case "/vi": data = Data(video.prefix(806))
      case "/vs": data = Data(video.dropFirst(806))
      case "/ai": data = Data(audio.prefix(764))
      case "/as": data = Data(audio.dropFirst(764))
      default: return (404, [:], Data())
      }
      return (200, [:], data)
    }
    let url = server.url("/manifest.mpd"), token = YlOpenCancellationToken()
    let scope = try YlManagedBufferLedger(maxBytes: 32 * 1024 * 1024).makeScope(maxBytes: nil)
    let resources = YlDashProgramResources(source: url, headers: [:], credentials: [:], configuration: .init(map: [:]), scope: scope)
    let program = try YlDashProgramDocument.parse(xml, source: url, final: url)
    let prepared = try YlPreparedDashProgram(program: program, resources: resources, scope: scope, cancellation: token)
    let texture = DashProgramTexture(); var display: DashProgramDisplay?
    var states: [YlNativeState] = [], failures: [NativePlayerError] = [], observations: [YlDashPlaybackObservation] = []
    let services = YlPlatformServices(platform: .current, textureOutput: texture,
      makeDisplayDriver: { let driver = DashProgramDisplay($0); display = driver; return driver })
    let backend = try YlDashProgramBackend(prepared: prepared, services: services, generation: 1, loadRequestId: "fixture", observe: { observations.append($0) }, emit: { callback in
      if case .state(let state) = callback.event { states.append(state) }
      if case .failure(let error) = callback.event { failures.append(error) }
    })
    defer { backend.dispose() }
    try backend.activate()
    XCTAssertEqual(states.last?.status, "ready")
    XCTAssertNil(states.last?.audioTracks.first?.label)
    XCTAssertEqual(states.last?.geometry?.encodedSize, CGSize(width: 320, height: 180))
    try backend.play()
    for _ in 0..<250 {
      display?.fire()
      if states.last?.status == "completed" || !failures.isEmpty { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(failures.isEmpty, failures.map(\.code).joined(separator: ","))
    XCTAssertEqual(states.last?.status, "completed"); XCTAssertEqual(states.last?.positionMs, 500)
    XCTAssertGreaterThan(texture.frames, 3)
    let times = observations.compactMap { event -> Int64? in if case .video(let time, _) = event { return time }; return nil }
    XCTAssertFalse(times.isEmpty); XCTAssertTrue(times.allSatisfy { $0 >= 0 && $0 < 500_000 })
    XCTAssertNil(backend.copyPixelBuffer())
    backend.stop(); backend.dispose(); backend.dispose()
  }
}

/// Uses the exact committed MPD/media bytes, served through the real managed transport.
@MainActor private final class DashProgramHarness {
  let server: DashHTTPServer
  let texture = DashProgramTexture()
  let scope: YlManagedBufferScope
  var display: DashProgramDisplay?
  var backend: YlDashProgramBackend!
  var states: [YlNativeState] = []
  var errors: [NativePlayerError] = []
  var video: [(Int64, UInt64, [UInt8])] = []
  var audio: [YlAudioClockSample] = []
  var periods: [(Int, Int64)] = []
  var joint: [[String: Any]] = []
  private var lastJointFrame: String?
  init(_ name: String, collectJoint: Bool = false, transform: ((String) -> String)? = nil, beforeRequest: ((String) -> Void)? = nil) throws {
    server = try DashHTTPServer()
    let data = try Data(contentsOf: XCTUnwrap(Bundle(for: YlDashSampleSourceNativeTests.self).url(forResource: "p01-program-fixtures", withExtension: "json")))
    let encoded = try JSONDecoder().decode([String: String].self, from: data)
    var files = encoded.compactMapValues { Data(base64Encoded: $0) }
    if let transform, let original = files[name + ".mpd"], let xml = String(data: original, encoding: .utf8) {
      files[name + ".mpd"] = Data(transform(xml).utf8)
    }
    let servedFiles = files
    server.handler = { request in
      beforeRequest?(request.path)
      guard let bytes = servedFiles[String(request.path.dropFirst())] else { return (404, [:], Data()) }
      if let range = request.headers["range"], range.hasPrefix("bytes=") {
        let pair = range.dropFirst(6).split(separator: "-")
        guard pair.count == 2, let start = Int(pair[0]), let end = Int(pair[1]), start >= 0, end >= start, end < bytes.count else { return (416, [:], Data()) }
        return (206, ["Content-Range": "bytes \(start)-\(end)/\(bytes.count)"], Data(bytes[start...end]))
      }
      return (200, [:], bytes)
    }
    let url = server.url("/" + name + ".mpd"), token = YlOpenCancellationToken()
    scope = try YlManagedBufferLedger(maxBytes: 64 * 1024 * 1024).makeScope(maxBytes: nil)
    let resources = YlDashProgramResources(source: url, headers: [:], credentials: [:], configuration: .init(map: [:]), scope: scope)
    let program = try YlDashProgramLoader.load(url: url, resources: resources, cancellation: token)
    let prepared = try YlPreparedDashProgram(program: program, resources: resources, scope: scope, cancellation: token)
    let services = YlPlatformServices(platform: .current, textureOutput: texture,
      makeDisplayDriver: { [weak self] in let value = DashProgramDisplay($0); self?.display = value; return value })
    backend = try YlDashProgramBackend(prepared: prepared, services: services, generation: 21, loadRequestId: "full-fixture", observe: { [weak self] event in
      guard let self else { return }
      switch event {
      case .video(let pts, let epoch): self.video.append((pts, epoch, self.texture.rgb))
      case .audio(let sample):
        self.audio.append(sample)
        if collectJoint, self.texture.visible, let frame = self.video.last,
           frame.1 == sample.generation {
          let key = "\(frame.1):\(frame.0)"
          let now = Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
          if key != self.lastJointFrame, let consumed = sample.position(atHostTimeUs: now) {
            self.lastJointFrame = key
            self.joint.append(["videoPtsUs": frame.0, "epoch": frame.1,
              "rgb": frame.2.map(Int.init), "audioPositionUs": sample.positionUs,
              "audioHostUs": sample.hostTimeUs, "observedHostUs": now,
              "audioProjectedUs": consumed, "deltaUs": frame.0 - consumed])
          }
        }
      case .period(let index, let wait): self.periods.append((index, wait))
      }
    }, emit: { [weak self] callback in
      if case .state(let state) = callback.event { self?.states.append(state) }
      if case .failure(let error) = callback.event { self?.errors.append(error) }
    })
    try backend.activate()
  }
  func advance(until condition: () -> Bool, seconds: Double = 7) async throws {
    let end = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() && errors.isEmpty && ProcessInfo.processInfo.systemUptime < end {
      display?.fire(); try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(errors.isEmpty, errors.map { $0.code + ": " + $0.message }.joined(separator: ","))
    XCTAssertTrue(condition(), "timeout; state=\(states.last?.status ?? "none") position=\(states.last?.positionMs ?? -1) frames=\(video.count)")
  }
  func seek(_ milliseconds: Int64) async throws {
    let backend = backend!
    try await Task.detached { try backend.seek(toMs: milliseconds, cancellationToken: nil) }.value
  }
  func close() { backend.dispose(); server.close() }
}

extension YlDashSampleSourceNativeTests {
  @MainActor func testProgramBackendClipsThreePointFiveAndSeeksOriginalClock() async throws {
    let harness = try DashProgramHarness("clip-end"); defer { harness.close() }
    try harness.backend.play()
    try await harness.advance(until: { harness.states.last?.status == "completed" })
    XCTAssertEqual(harness.states.last?.positionMs, 3500)
    XCTAssertTrue(harness.video.allSatisfy { $0.0 >= 0 && $0.0 < 3_500_000 })
    for (target, rgb) in [(Int64(500_000), [255, 0, 0]), (Int64(3_450_000), [255, 255, 255])] {
      let marker = try XCTUnwrap(harness.video.last { $0.0 <= target })
      XCTAssertLessThan(target - marker.0, 100_000)
      XCTAssertEqual(marker.2.count, 3)
      for (a, b) in zip(marker.2, rgb) { XCTAssertLessThan(abs(Int(a) - b), 12, "marker \(target): \(marker.2)") }
    }
    XCTAssertFalse(harness.audio.isEmpty)
    XCTAssertNil(harness.backend.copyPixelBuffer())
    for target: Int64 in [3800, 500, 3450, 3500, 500] {
      let before = harness.video.count
      try await harness.seek(target)
      if target < 3500 {
        try await harness.advance(until: { harness.video.count > before })
        let first = harness.video[before]
        XCTAssertGreaterThanOrEqual(first.0, target * 1000)
        XCTAssertLessThan(first.0 - target * 1000, 100_000)
      } else { XCTAssertNil(harness.backend.copyPixelBuffer()); XCTAssertEqual(harness.states.last?.positionMs, 3500) }
    }
    harness.backend.stop(); XCTAssertNil(harness.backend.copyPixelBuffer())
  }
  @MainActor func testProgramBackendIndependentPTOAndNaturalPeriods() async throws {
    for name in ["independent-pto", "manifest", "gap", "overlap"] {
      let harness = try DashProgramHarness(name)
      defer { harness.close() }
      try harness.backend.setPlaybackSpeed(2)
      try harness.backend.play()
      try await harness.advance(until: { harness.states.last?.status == "completed" }, seconds: 10)
      let duration: Int64 = name == "gap" ? 9000 : name == "overlap" ? 7000 : name == "manifest" ? 8000 : 4000
      XCTAssertEqual(harness.states.last?.positionMs, duration, name)
      XCTAssertTrue(harness.video.allSatisfy { $0.0 >= 0 && $0.0 < duration * 1000 }, name)
      if name != "independent-pto" {
        let boundary: Int64 = name == "gap" ? 5_000_000 : name == "overlap" ? 3_000_000 : 4_000_000
        XCTAssertTrue(harness.video.contains { $0.0 >= boundary && $0.2.count == 3 && $0.2[0] > 240 && $0.2[1] > 240 && $0.2[2] < 12 }, name)
        XCTAssertEqual(harness.periods.map(\.0), [1], name)
        if name == "gap" { XCTAssertFalse(harness.video.contains { (4_000_000..<5_000_000).contains($0.0) }) }
        if name == "overlap" { XCTAssertFalse(harness.video.contains { $0.1 == 1 && $0.0 >= 3_000_000 }) }
      }
      harness.close()
      try await Task.sleep(nanoseconds: 100_000_000)
      XCTAssertEqual(harness.scope.ledger.snapshot.currentBytes, 0, name)
    }
  }
}

extension YlDashSampleSourceNativeTests {
  @MainActor func testPublicProgramLoadCommandsAndManagedPolicy() async throws {
    let server = try DashHTTPServer(); defer { server.close() }
    let data = try Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "p01-program-fixtures", withExtension: "json")))
    let files = try JSONDecoder().decode([String: String].self, from: data).compactMapValues { Data(base64Encoded: $0) }
    server.handler = { request in
      let path = request.path.replacingOccurrences(of: "/proxy/mpd/", with: "/")
      let name = path == "/.bin" ? "independent-pto.mpd" : String(path.dropFirst())
      guard request.headers["authorization"] == "owned-program", let bytes = files[name] else { return (403, [:], Data()) }
      if name.hasSuffix(".mpd") {
        let xml = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "<MPD ",
          with: "<MPD xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\" xsi:schemaLocation=\"urn:mpeg:dash:schema:mpd:2011 DASH-MPD.xsd\" ")
        return (200, ["Content-Type": "application/dash+xml"], Data(xml.utf8))
      }
      return (200, [:], bytes)
    }
    for mode in 0..<3 {
      let texture = DashProgramTexture(); var display: DashProgramDisplay?
      var states: [YlNativeState] = [], errors: [NativePlayerError] = []
      let services = YlPlatformServices(platform: .current, textureOutput: texture,
        makeDisplayDriver: { let value = DashProgramDisplay($0); display = value; return value })
      let coordinator = YlAppleSessionCoordinator(playerId: 99, services: services,
        configuration: .init(map: ["audioPolicy": "appManaged"]),
        textureOwner: .init(output: texture, onFrame: { _ in }), emit: { identity, event in
          XCTAssertEqual(identity.sessionId, "program-public")
          if case .state(let state) = event.event { states.append(state) }
          if case .failure(let error) = event.event { errors.append(error) }
        })
      defer { coordinator.dispose() }
      let source = YlAppleSourceDescriptor(uri: server.url(mode == 0 ? "/proxy/mpd/.bin" : "/independent-pto.mpd").absoluteString,
        kind: .network, formatHint: mode == 0 ? .automatic : .dash, credentials: ["Authorization": "owned-program"],
        networkPolicy: mode == 1 ? .managed : .platformDefault,
        loadOptions: .init(autoplay: true, startPositionMs: 500, decoderPolicy: mode == 2 ? .hardwareRequired : .systemDefault))
      do { try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        coordinator.load(.init(source: source), identity: .init(sessionId: "program-public", loadRequestId: "load"),
          willCommit: { XCTAssertTrue($0) }, didCommit: {}, didRollback: {},
          completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
      }
      } catch let error as NativePlayerError {
        #if targetEnvironment(simulator)
        if mode == 2 {
          // This is strict-policy denial coverage, never hardware playback evidence.
          XCTAssertEqual(error.code, "decoder.unavailable")
          XCTAssertNil(coordinator.identity); XCTAssertEqual(texture.frames, 0)
          continue
        }
        #endif
        XCTFail("Load mode \(mode): \(error.code)"); throw error
      }
      func command(_ value: YlApplePlaybackCommand) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
          coordinator.execute(value) { continuation.resume(with: $0.mapError { $0 as Error }) }
        }
      }
      func frames(after count: Int) async throws {
        for _ in 0..<250 {
          display?.fire()
          if texture.frames > count || !errors.isEmpty { break }
          try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(texture.frames, count)
        XCTAssertTrue(errors.isEmpty, errors.map(\.code).joined(separator: ","))
      }
      try await frames(after: 0)
      let current = try XCTUnwrap(states.last)
      XCTAssertEqual(current.engine, .managedFallback)
      if mode == 2 { XCTAssertTrue(current.isHardwareDecoding); XCTAssertEqual(current.decoderEvidence?.mode, .hardware) }
      XCTAssertGreaterThanOrEqual(current.positionMs, 500)
      XCTAssertEqual(current.durationMs, 4000)
      let audio = try XCTUnwrap(current.audioTracks.first?.id), video = try XCTUnwrap(current.videoTracks.first?.id)
      try await command(.pause)
      try await command(.seek(2500))
      try await command(.constraints(.init(maxWidth: 320, maxHeight: 180, maxBitrate: 350000)))
      try await command(.videoTrack(video))
      try await command(.track(audio))
      let count = texture.frames
      try await command(.play); try await frames(after: count)
      do { try await command(.track("absent-content")); XCTFail("missing audio silently substituted") }
      catch { XCTAssertEqual((error as? NativePlayerError)?.code, "track.not_found") }
      XCTAssertEqual(coordinator.identity?.sessionId, "program-public")
      coordinator.deactivate()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        coordinator.beginActivation(forcePlay: true, willCommit: { XCTAssertTrue($0) }, didCommit: {}, didRollback: {},
          completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
      }
      let restored = texture.frames
      try await command(.play); try await frames(after: restored)
      try await command(.seek(4000))
      let completedFrames = texture.frames
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        coordinator.beginActivation(forcePlay: true, willCommit: { _ in }, didCommit: {}, didRollback: {},
          completion: { continuation.resume(with: $0.mapError { $0 as Error }) })
      }
      try await frames(after: completedFrames)
      XCTAssertLessThan(states.last?.positionMs ?? 4000, 4000)
      coordinator.stop(); coordinator.dispose()
    }
  }
}

extension YlDashSampleSourceNativeTests {
  func testActualDecodedPCMClipsExactlyThreePointFiveSecondsAndKeepsBothToneMarkers() throws {
    let bundle = Bundle(for: Self.self)
    let encoded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: XCTUnwrap(bundle.url(forResource: "p01-program-fixtures", withExtension: "json"))))
    let files = encoded.compactMapValues { Data(base64Encoded: $0) }
    let url = URL(string: "https://owned.example/clip")!
    let scope = try YlManagedBufferLedger(maxBytes: 32 * 1024 * 1024).makeScope(maxBytes: nil)
    let window = try YlDashProgramTimeline.Window(start: YlDashProgramTime(0), end: YlDashProgramTime(7, 2))
    let converter = YlDashAudioConverter(window: window, scope: scope)
    var configured = false, frames = 0
    let windows = [12000..<36000, 156000..<167520]
    var counts = [0, 0], crossings = [0, 0], previous: [Float] = [0, 0]
    for number in 1...5 {
      let initialization = try XCTUnwrap(files["period0/init-1.m4s"])
      let fragment = try XCTUnwrap(files[String(format: "period0/chunk-1-%05d.m4s", number)])
      let source = try YlDashSampleSource(initialization: .init(data: initialization, finalURL: url, credentialsStripped: false, resourceLength: nil, reservation: nil),
        fragment: .init(data: fragment, finalURL: url, credentialsStripped: false, resourceLength: nil, reservation: nil), kind: .audio, cancellation: .init(), scope: scope)
      if !configured {
        try converter.configure(stream: .init(codec: .aac, sampleRate: 48000, channelCount: 1, magicCookie: source.codecConfiguration, generation: 1))
        configured = true
      }
      while let packet = try source.next() {
        let key = try packet.pts.converted(to: 1_000_000, rounding: .floor)
        try converter.register(packet.pts, forMicroseconds: key)
        let input = try YlCompressedAudioPacket(data: packet.audioBytes(), ptsUs: key,
          durationUs: packet.duration.converted(to: 1_000_000, rounding: .ceil), generation: 1)
        guard let decoded = try converter.convert(packet: input), let pcm = decoded.payload as? AVAudioPCMBuffer else { continue }
        let samples = try XCTUnwrap(pcm.floatChannelData?[0])
        let start = Int((Double(decoded.ptsUs) * 48000 / 1_000_000).rounded())
        frames += Int(pcm.frameLength)
        XCTAssertGreaterThanOrEqual(start, 0)
        XCTAssertLessThanOrEqual(start + Int(pcm.frameLength), 168000)
        for index in 0..<Int(pcm.frameLength) {
          for marker in 0..<2 where windows[marker].contains(start + index) {
            if previous[marker] <= 0 && samples[index] > 0 { crossings[marker] += 1 }
            previous[marker] = samples[index]; counts[marker] += 1
          }
        }
      }
    }
    XCTAssertEqual(frames, 168000)
    XCTAssertEqual(counts, windows.map(\.count))
    for marker in 0..<2 {
      XCTAssertEqual(Double(crossings[marker]) * 48000 / Double(counts[marker]), marker == 0 ? 440 : 1760, accuracy: 8)
    }
    converter.reset()
  }
}


extension YlDashSampleSourceNativeTests {
  @MainActor func testProgramSeekIntoDeclaredEmptyTailCompletesWithoutInventingSamples() async throws {
    let harness = try DashProgramHarness("independent-pto", transform: { $0.replacingOccurrences(of: "PT4S", with: "PT5S") })
    defer { harness.close() }
    try await harness.seek(4500)
    try harness.backend.play()
    try await harness.advance(until: { harness.states.last?.status == "completed" }, seconds: 2)
    XCTAssertEqual(harness.states.last?.positionMs, 5000)
    XCTAssertTrue(harness.video.isEmpty)
    XCTAssertTrue(harness.audio.isEmpty)
    XCTAssertNil(harness.backend.copyPixelBuffer())
  }

  @MainActor func testProgramCrossCodecResolutionAndBackwardSeekPublishRealHEVCPixels() async throws {
    let harness = try DashProgramHarness("cross-codec"); defer { harness.close() }
    harness.backend.emitState()
    let fixed = try XCTUnwrap(harness.states.last?.videoTracks.first?.id), backend = harness.backend!
    try await Task.detached {
      try backend.updateVideoConstraints(.init(maxWidth: 640, maxHeight: 360, maxBitrate: 650000), cancellationToken: nil)
      try backend.selectVideoTrack(fixed, cancellationToken: nil)
    }.value
    try harness.backend.play()
    try await harness.advance(until: { harness.states.last?.status == "completed" }, seconds: 6)
    XCTAssertTrue(harness.states.contains { $0.videoWidth == 640 && $0.videoHeight == 360 })
    XCTAssertNil(harness.backend.videoSelection.fixedTrackId)
    XCTAssertEqual(harness.backend.videoSelection.reason, "trackUnavailable")
    XCTAssertTrue(harness.video.contains { $0.0 >= 1_500_000 && $0.0 < 2_500_000 && $0.2.count == 3 && $0.2[0] > 240 && $0.2[1] > 240 && $0.2[2] < 12 })
    XCTAssertTrue(harness.video.contains { $0.0 >= 2_500_000 && $0.2.count == 3 && $0.2[0] < 12 && $0.2[1] > 240 && $0.2[2] > 240 })
    for target: Int64 in [500, 2000, 750] {
      let before = harness.video.count
      try await harness.seek(target)
      try await harness.advance(until: { harness.video.count > before })
      XCTAssertEqual(harness.states.last?.videoWidth, target < 1500 ? 320 : 640)
      XCTAssertGreaterThanOrEqual(harness.video[before].0, target * 1000)
    }
  }

  @MainActor func testProgramAudioIdentitySurvivesCatalogAddition() async throws {
    let harness = try DashProgramHarness("audio-added"); defer { harness.close() }
    harness.backend.emitState()
    let first = try XCTUnwrap(harness.states.last)
    let audio = try XCTUnwrap(first.audioTracks.first?.id)
    let video = try XCTUnwrap(first.videoTracks.first?.id)
    let backend = harness.backend!
    try await Task.detached { try backend.selectAudioTrack(audio, cancellationToken: nil); try backend.selectVideoTrack(video, cancellationToken: nil) }.value
    try harness.backend.play()
    try await harness.advance(until: { harness.states.last?.status == "completed" })
    XCTAssertEqual(harness.states.last?.audioTracks.count, 2)
    XCTAssertEqual(harness.states.last?.audioTracks.first(where: \.isSelected)?.id, audio)
    XCTAssertTrue(harness.errors.isEmpty)
  }

  @MainActor func testProgramMissingExplicitAudioRejectsCandidateWithoutReplacingAcceptedTrack() async throws {
    let harness = try DashProgramHarness("audio-removed"); defer { harness.close() }
    harness.backend.emitState()
    let audio = try XCTUnwrap(harness.states.last?.audioTracks.first?.id)
    let backend = harness.backend!
    try await Task.detached { try backend.selectAudioTrack(audio, cancellationToken: nil) }.value
    do { try await harness.seek(2000); XCTFail("missing explicit audio must reject") }
    catch { XCTAssertEqual((error as? NativePlayerError)?.code, "track.not_found") }
    harness.backend.emitState()
    XCTAssertEqual(harness.states.last?.audioTracks.first(where: \.isSelected)?.id, audio)
    XCTAssertLessThan(harness.states.last?.positionMs ?? 3000, 1500)
    try harness.backend.play()
    try await harness.advance(until: { !harness.video.isEmpty }, seconds: 2)
    for _ in 0..<400 {
      harness.display?.fire()
      if !harness.errors.isEmpty { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(harness.errors.last?.code, "track.not_found")
    XCTAssertEqual(harness.states.last?.audioTracks.first(where: \.isSelected)?.id, audio)
  }
}


extension YlDashSampleSourceNativeTests {
  @MainActor func testProgramVideoOnlyWaitsForActualCoverageAndResumesAfterDelayedFragment() async throws {
    let held = expectation(description: "video fragment pending"), release = DispatchSemaphore(value: 0)
    let harness = try DashProgramHarness("independent-pto", transform: { xml in
      var xml = xml
      let start = xml.range(of: "<AdaptationSet contentType=\"audio\"")!.lowerBound
      let end = xml.range(of: "</AdaptationSet>", range: start..<xml.endIndex)!.upperBound
      xml.removeSubrange(start..<end); return xml
    }, beforeRequest: { path in
      if path == "/independent/chunk-0-00002.m4s" { held.fulfill(); _ = release.wait(timeout: .now() + 6) }
    })
    defer { release.signal(); harness.close() }
    try harness.backend.play()
    try await harness.advance(until: { harness.server.requests.contains { $0.path == "/independent/chunk-0-00002.m4s" } }, seconds: 2)
    await fulfillment(of: [held], timeout: 2)
    for _ in 0..<150 { harness.display?.fire(); try await Task.sleep(nanoseconds: 10_000_000) }
    harness.backend.emitState()
    XCTAssertLessThanOrEqual(harness.states.last?.positionMs ?? .max, 1000)
    XCTAssertEqual(harness.states.last?.status, "buffering")
    XCTAssertNil(harness.backend.copyPixelBuffer(), "expired frame must not cover missing media")
    release.signal()
    try await harness.advance(until: { harness.states.last?.status == "completed" }, seconds: 5)
    XCTAssertTrue(harness.video.contains { $0.0 >= 1_000_000 && $0.0 < 1_100_000 }, "resume cannot skip the delayed fragment")
  }

  @MainActor func testProgramCancelledCandidateCannotChangeCatalogOrAcceptedOutput() async throws {
    let held = expectation(description: "candidate pending"), release = DispatchSemaphore(value: 0)
    let harness = try DashProgramHarness("cross-codec", beforeRequest: { path in
      if path == "/hevc/init-0.m4s" { held.fulfill(); _ = release.wait(timeout: .now() + 5) }
    })
    defer { release.signal(); harness.close() }
    let backend = harness.backend!, token = YlOpenCancellationToken()
    let pending = Task.detached { try backend.seek(toMs: 2000, cancellationToken: token) }
    await fulfillment(of: [held], timeout: 2)
    token.cancel()
    do { try await pending.value; XCTFail("cancelled seek committed") }
    catch { XCTAssertTrue(token.isCancelled) }
    release.signal()
    harness.backend.emitState()
    XCTAssertEqual(harness.states.last?.videoWidth, 320)
    XCTAssertEqual(harness.states.last?.positionMs, 0)
    XCTAssertTrue(harness.periods.isEmpty)
    try harness.backend.play()
    try await harness.advance(until: { !harness.video.isEmpty }, seconds: 2)
    XCTAssertTrue(harness.video.allSatisfy { $0.1 == 1 })
  }
}


extension YlDashSampleSourceNativeTests {
  @MainActor func testProgramCompletedPlayHonorsCommandCancellationDuringReload() async throws {
    let harness = try DashProgramHarness("independent-pto", transform: { $0.replacingOccurrences(of: "PT4S", with: "PT0.5S") })
    let release = DispatchSemaphore(value: 0)
    defer { release.signal(); harness.close() }
    try harness.backend.play()
    try await harness.advance(until: { harness.states.last?.status == "completed" }, seconds: 2)
    let held = expectation(description: "restart pending"), original = harness.server.handler!
    harness.server.handler = { request in
      if request.path == "/independent/init-0.m4s" { held.fulfill(); _ = release.wait(timeout: .now() + 4) }
      return original(request)
    }
    let backend = harness.backend!, token = YlOpenCancellationToken()
    let pending = Task.detached { try YlApplePlaybackCommand.play.apply(to: backend, cancellationToken: token) }
    await fulfillment(of: [held], timeout: 2)
    token.cancel(); release.signal()
    do { try await pending.value; XCTFail("restart ignored command cancellation") }
    catch { XCTAssertTrue(token.isCancelled) }
    harness.backend.emitState()
    XCTAssertEqual(harness.states.last?.status, "completed")
    XCTAssertEqual(harness.states.last?.positionMs, 500)
  }
}


extension YlDashSampleSourceNativeTests {
  @MainActor func testProgramAbsoluteFragmentOffsetsSurviveManagedSegmentBaseAndListRanges() async throws {
    for name in ["absolute-base", "absolute-list"] {
      let harness: DashProgramHarness
      do { harness = try DashProgramHarness(name) }
      catch let error as NativePlayerError { XCTFail("\(name): \(error.code): \(error.message)"); throw error }
      defer { harness.close() }
      try harness.backend.play()
      try await harness.advance(until: { harness.states.last?.status == "completed" }, seconds: 6)
      XCTAssertEqual(harness.states.last?.positionMs, 4000)
      XCTAssertTrue(harness.video.contains { $0.0 < 1_000_000 && $0.2.count == 3 && $0.2[0] > 240 && $0.2[1] < 12 })
      for target: Int64 in [500, 2500] {
        let before = harness.video.count
        try await harness.seek(target)
        try await harness.advance(until: { harness.video.count > before })
        XCTAssertGreaterThanOrEqual(harness.video[before].0, target * 1000)
      }
      XCTAssertTrue(harness.server.requests.filter { $0.path == "/absolute-range.m4s" }.allSatisfy { $0.headers["range"] != nil })
    }
  }
}


extension YlDashSampleSourceNativeTests {
  func testSparseFragmentKeepsAbsoluteOffsetsAboveFourGiBWithoutAllocatingHole() throws {
    let encoded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "p01-program-fixtures", withExtension: "json"))))
    let files = encoded.compactMapValues { Data(base64Encoded: $0) }
    let initialization = try XCTUnwrap(files["period0/init-0.m4s"]), packed = try XCTUnwrap(files["absolute-range.m4s"])
    func word(_ start: Int) -> Int { packed[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) } }
    let start = initialization.count + 80 + 4096, length = word(initialization.count + 32)
    var fragment = Data(packed[start..<(start + length)])
    let field = try XCTUnwrap(fragment.range(of: Data("tfhd".utf8))).lowerBound + 12
    let original = fragment[field..<(field + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    let delta: UInt64 = 1 << 33
    var absolute = (original + delta).bigEndian
    fragment.replaceSubrange(field..<(field + 8), with: withUnsafeBytes(of: &absolute) { Data($0) })
    let scope = try YlManagedBufferLedger(maxBytes: 4 * 1024 * 1024).makeScope(maxBytes: nil)
    let url = URL(string: "https://owned.example/sparse")!
    let source = try YlDashSampleSource(initialization: .init(data: initialization, finalURL: url, credentialsStripped: false, resourceLength: nil, reservation: nil),
      fragment: .init(data: fragment, finalURL: url, credentialsStripped: false, resourceLength: nil, reservation: nil, sourceOffset: Int64(start) + Int64(delta)),
      kind: .video, cancellation: .init(), scope: scope)
    var clocks: [Int64] = []
    while let packet = try source.next() { clocks.append(try packet.pts.converted(to: 12288, rounding: .floor)) }
    XCTAssertEqual(clocks, (0..<24).map { Int64($0 * 512) })
    XCTAssertLessThan(scope.ledger.snapshot.currentBytes, 1024 * 1024)
  }
}


extension YlDashSampleSourceNativeTests {
  @MainActor func testProgramSameCodecResolutionChangeAndCapsRemainAuthoritative() async throws {
    for width in [640, 320] {
      let harness = try DashProgramHarness("resolution"); defer { harness.close() }
      harness.backend.emitState()
      let fixed = try XCTUnwrap(harness.states.last?.videoTracks.first?.id), backend = harness.backend!
      try await Task.detached {
        try backend.updateVideoConstraints(.init(maxWidth: width, maxHeight: nil, maxBitrate: nil), cancellationToken: nil)
        try backend.selectVideoTrack(fixed, cancellationToken: nil)
      }.value
      try harness.backend.play()
      if width == 640 {
        try await harness.advance(until: { harness.states.last?.status == "completed" })
        XCTAssertEqual(harness.states.last?.videoWidth, 640)
        XCTAssertNil(harness.backend.videoSelection.fixedTrackId)
        XCTAssertEqual(harness.backend.videoSelection.reason, "trackUnavailable")
        XCTAssertTrue(harness.video.contains { $0.0 >= 1_500_000 && $0.2.count == 3 && $0.2[0] > 240 && $0.2[1] > 240 && $0.2[2] < 12 })
      } else {
        for _ in 0..<400 {
          harness.display?.fire()
          if !harness.errors.isEmpty { break }
          try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(harness.errors.last?.code, YlAppleVideoConstraints.unsupportedOutput.code)
        XCTAssertFalse(harness.states.contains { ($0.videoWidth ?? 0) > width })
        XCTAssertFalse(harness.video.contains { $0.0 >= 1_500_000 })
      }
    }
  }
}


extension YlDashSampleSourceNativeTests {
  @MainActor func testProgramAudioLeadingAndInternalGapsDoNotCompressVideoTime() async throws {
    for leading in [true, false] {
      let harness = try DashProgramHarness("independent-pto", transform: { xml in
        if leading { return xml.replacingOccurrences(of: "presentationTimeOffset=\"960000\"", with: "presentationTimeOffset=\"936000\"") }
        var xml = xml
        let adaptation = xml.range(of: "<AdaptationSet contentType=\"audio\"")!.lowerBound
        let start = xml.range(of: "<SegmentTemplate", range: adaptation..<xml.endIndex)!.lowerBound
        let end = xml.range(of: "</SegmentTemplate>", range: start..<xml.endIndex)!.upperBound
        let replacement = """
        <SegmentList timescale="48000" presentationTimeOffset="960000"><Initialization sourceURL="init-1.m4s"/><SegmentTimeline><S t="960000" d="47104"/><S t="1055232" d="48128"/><S t="1103360" d="48128"/><S t="1151488" d="512"/></SegmentTimeline><SegmentURL media="chunk-1-00001.m4s"/><SegmentURL media="chunk-1-00003.m4s"/><SegmentURL media="chunk-1-00004.m4s"/><SegmentURL media="chunk-1-00005.m4s"/></SegmentList>
        """
        xml.replaceSubrange(start..<end, with: replacement); return xml
      })
      defer { harness.close() }
      let started = ProcessInfo.processInfo.systemUptime
      try harness.backend.play()
      try await harness.advance(until: { harness.states.last?.status == "completed" }, seconds: 7)
      XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime - started, 3.85)
      XCTAssertTrue(harness.video.contains { $0.0 >= 250_000 && $0.0 <= 350_000 }, "leading audio cannot skip early video")
      XCTAssertTrue(harness.video.contains { $0.0 >= 1_450_000 && $0.0 <= 1_550_000 }, "internal gap keeps programme time; leading=\(leading) published=\(harness.video.filter { $0.0 >= 1_000_000 && $0.0 < 2_000_000 }.map { $0.0 })")
      XCTAssertEqual(harness.states.last?.positionMs, 4000)
    }
  }
}

extension YlDashSampleSourceNativeTests {
  func testAudioTimelineSchedulesExactBoundedSilenceAndOriginalPCM() throws {
    let encoded = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "p01-program-fixtures", withExtension: "json"))))
    let files = encoded.compactMapValues { Data(base64Encoded: $0) }
    for leading in [true, false] {
      let scope = try YlManagedBufferLedger(maxBytes: 4 * 1024 * 1024).makeScope(maxBytes: nil)
      let url = URL(string: "https://owned.example/audio-gap")!
      let window = try YlDashProgramTimeline.Window(start: .init(0), end: .init(4))
      let timeline = YlDashAudioTimeline(window: window, scope: scope)
      var configured = false, frames = 0, silenceFrames = 0, silencePeak: Float = 0
      var crossings = 0, toneFrames = 0, previous: Float = 0
      let silenceWindow = leading ? 0..<20000 : 52800..<86400
      let toneWindow = leading ? 30000..<42000 : 12000..<36000
      for number in 1...5 where leading || number != 2 {
        let source = try YlDashSampleSource(initialization: .init(data: XCTUnwrap(files["period0/init-1.m4s"]), finalURL: url, credentialsStripped: false, resourceLength: nil, reservation: nil),
          fragment: .init(data: XCTUnwrap(files[String(format: "period0/chunk-1-%05d.m4s", number)]), finalURL: url, credentialsStripped: false, resourceLength: nil, reservation: nil),
          kind: .audio, cancellation: .init(), scope: scope)
        if !configured {
          try timeline.configure(stream: .init(codec: .aac, sampleRate: 48000, channelCount: 1, magicCookie: source.codecConfiguration, generation: 1))
          configured = true
        }
        while let packet = try source.next() {
          let pts = try packet.pts.adding(leading ? .init(1, 2) : .init(0))
          let input = try YlCompressedAudioPacket(data: packet.audioBytes(), ptsUs: pts.converted(to: 1_000_000, rounding: .floor),
            durationUs: packet.duration.converted(to: 1_000_000, rounding: .ceil), generation: 1)
          try timeline.decode(input, pts: pts)
          while let submission = try timeline.nextSubmission() {
            let output = try XCTUnwrap(timeline.convert(packet: submission))
            let pcm = try XCTUnwrap(output.payload as? AVAudioPCMBuffer), samples = try XCTUnwrap(pcm.floatChannelData?[0])
            let start = Int((Double(output.ptsUs) * 48000 / 1_000_000).rounded())
            XCTAssertEqual(start, frames, "No unrepresented gap or overlap")
            XCTAssertLessThanOrEqual(output.durationUs, 100000)
            XCTAssertLessThan(scope.ledger.snapshot.currentBytes, 2 * 1024 * 1024)
            for index in 0..<Int(pcm.frameLength) {
              if silenceWindow.contains(start + index) { silencePeak = max(silencePeak, abs(samples[index])); silenceFrames += 1 }
              if toneWindow.contains(start + index) {
                if previous <= 0 && samples[index] > 0 { crossings += 1 }
                previous = samples[index]; toneFrames += 1
              }
            }
            frames += Int(pcm.frameLength)
          }
        }
      }
      XCTAssertEqual(frames, 192000)
      XCTAssertEqual(silenceFrames, silenceWindow.count); XCTAssertEqual(silencePeak, 0)
      XCTAssertEqual(toneFrames, toneWindow.count)
      XCTAssertEqual(Double(crossings) * 48000 / Double(toneFrames), 440, accuracy: 8)
      timeline.reset()
    }
  }
}


extension YlDashSampleSourceNativeTests {
  /// Three fresh resource scopes per fixture. Audio pairs come from native
  /// rendered output time, not submitted PCM or the public state projection.
  @MainActor func testProgramNativeJointBaseline() async throws {
    for name in ["manifest", "independent-pto", "clip-end", "cross-codec", "resolution"] {
      for run in 0..<3 {
        let started = ProcessInfo.processInfo.systemUptime
        let harness = try DashProgramHarness(name, collectJoint: true)
        defer { harness.close() }
        let readyMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        try harness.backend.play()
        try await harness.advance(until: { harness.states.last?.status == "completed" }, seconds: 14)
        XCTAssertGreaterThan(harness.joint.count, 12, name)
        let boundary: Int64? = name == "manifest" ? 4_000_000 :
          (name == "cross-codec" || name == "resolution") ? 1_500_000 : nil
        if let boundary {
          XCTAssertTrue(harness.joint.contains { ($0["videoPtsUs"] as! Int64) >= boundary }, name)
          XCTAssertTrue(harness.audio.contains { $0.positionUs >= boundary }, name)
        }
        for row in harness.joint {
          let pts = row["videoPtsUs"] as! Int64
          let second = boundary.map { pts >= $0 } ?? false
          let local = pts - (second ? boundary! : 0)
          let colors = second ? [[255,255,0],[0,255,255],[255,0,255],[0,0,0]] :
            [[255,0,0],[0,255,0],[0,0,255],[255,255,255]]
          let expected = colors[min(3, Int(local / 1_000_000))]
          let rgb = row["rgb"] as! [Int]
          XCTAssertEqual(rgb.count, 3)
          for (value, reference) in zip(rgb, expected) {
            XCTAssertLessThan(abs(value - reference), 24, "\(name) pts=\(pts) RGB=\(rgb)")
          }
        }
        let peak = harness.scope.ledger.snapshot.peakBytes
        let waits = harness.periods.map { ["period": Int64($0.0), "waitMs": $0.1] }
        let rows = harness.joint
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - started) * 1000
        harness.close()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(harness.scope.ledger.snapshot.currentBytes, 0)
        let record: [String: Any] = ["fixture": name, "run": run,
          "readyMs": readyMs, "elapsedMs": elapsedMs, "peakBytes": peak,
          "releasedBytes": harness.scope.ledger.snapshot.currentBytes,
          "periodWaits": waits, "rows": rows]
        let json = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        print("YL_P01_JOINT " + String(decoding: json, as: UTF8.self))
      }
    }
  }
}

extension YlDashSampleSourceNativeTests {
  /// The high-bitrate alternative carries real PQ metadata in its sample
  /// configuration. Its coded color is only an identity fixture, not HDR QA.
  private func verifyPQFamilyFixture() throws {
    let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "p01-program-fixtures", withExtension: "json"))
    let files = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
    let initialization = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(files["family-pq/init-0.m4s"])))
    let fragment = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(files["family-pq/chunk-0-00001.m4s"])))
    let scope = try YlManagedBufferLedger(maxBytes: 4 * 1024 * 1024).makeScope(maxBytes: nil)
    let source = try YlDashSampleSource(
      initialization: .init(data: initialization, finalURL: url, credentialsStripped: false, resourceLength: nil, reservation: nil),
      fragment: .init(data: fragment, finalURL: url, credentialsStripped: false, resourceLength: nil, reservation: nil),
      kind: .video, cancellation: .init(), scope: scope)
    let format = try XCTUnwrap(source.videoFormat)
    let transfer = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
    XCTAssertEqual(transfer, kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
    guard transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String else {
      throw NSError(domain: "OwnedPQFixtureMissingTransfer", code: 1)
    }
  }

  private func mixedVideoFamilies(_ xml: String) -> String {
    let period = xml.range(of: "<Period id=\"period1\"")!
    let start = xml.range(of: "<Representation", range: period.lowerBound..<xml.endIndex)!
    let end = xml.range(of: "</Representation>", range: start.lowerBound..<xml.endIndex)!
    let sdr = String(xml[start.lowerBound..<end.upperBound])
    let pq = sdr.replacingOccurrences(of: "id=\"0\"", with: "id=\"pq\"")
      .replacingOccurrences(of: "bandwidth=\"650000\"", with: "bandwidth=\"900000\"")
      .replacingOccurrences(of: "initialization=\"init-0.m4s\"", with: "initialization=\"../family-pq/init-0.m4s\"")
      .replacingOccurrences(of: "media=\"chunk-0-", with: "media=\"../family-pq/chunk-0-")
    return xml.replacingCharacters(in: end.upperBound..<end.upperBound, with: pq)
  }

  @MainActor func testProgramAcceptedVideoFamilySurvivesDeactivationAndEndSeek() async throws {
    try verifyPQFamilyFixture()
    let harness = try DashProgramHarness("resolution", transform: mixedVideoFamilies)
    defer { harness.close() }
    try await harness.seek(2000)
    harness.backend.emitState()
    XCTAssertEqual(harness.states.last?.videoTracks.first(where: \.isSelected)?.bitrate, 650000)
    for retirement in 0..<2 {
      if retirement == 0 {
        harness.backend.deactivate()
        try harness.backend.activate()
        try await harness.advance(until: { harness.periods.count >= 2 })
      } else {
        try await harness.seek(3000)
        XCTAssertEqual(harness.states.last?.status, "completed")
        try await harness.seek(2000)
      }
      harness.backend.emitState()
      XCTAssertEqual(harness.states.last?.videoTracks.first(where: \.isSelected)?.bitrate, 650000,
        "Pipeline retirement must retain the accepted SDR family")
    }
    // Prove the alternative is admitted and selectable; an unavailable PQ
    // fixture must not let the automatic-selection assertions pass vacuously.
    let pq = try XCTUnwrap(harness.states.last?.videoTracks.first { $0.bitrate == 900000 }?.id)
    let backend = harness.backend!
    try await Task.detached { try backend.selectVideoTrack(pq, cancellationToken: nil) }.value
    backend.emitState()
    XCTAssertEqual(harness.states.last?.videoTracks.first(where: \.isSelected)?.bitrate, 900000)
    // A successful explicit selection becomes the new accepted family. SDR-only
    // Period zero must then fail, without replacing the accepted PQ pipeline.
    do { try await harness.seek(500); XCTFail("automatic seek crossed the accepted PQ family") }
    catch { XCTAssertEqual((error as? NativePlayerError)?.code, YlAppleVideoConstraints.unsupportedOutput.code) }
    backend.emitState()
    XCTAssertEqual(harness.states.last?.videoTracks.first(where: \.isSelected)?.bitrate, 900000)
  }

  @MainActor func testProgramFailedCandidatePreservesVideoFamilyForRestoration() async throws {
    try verifyPQFamilyFixture()
    let harness = try DashProgramHarness("resolution", transform: mixedVideoFamilies)
    defer { harness.close() }
    try await harness.seek(2000)
    let backend = harness.backend!
    do {
      try await Task.detached { try backend.selectAudioTrack("absent-content", cancellationToken: nil) }.value
      XCTFail("missing audio candidate must fail after video preparation")
    } catch { XCTAssertEqual((error as? NativePlayerError)?.code, "track.not_found") }
    backend.deactivate()
    try backend.activate()
    try await harness.advance(until: { harness.periods.count >= 2 })
    backend.emitState()
    XCTAssertEqual(harness.states.last?.videoTracks.first(where: \.isSelected)?.bitrate, 650000)
    XCTAssertEqual(harness.states.last?.audioTracks.filter(\.isSelected).count, 1)
  }
}

// Test-only timestamps from AVPlayerItemVideoOutput, bound to buffers actually
// published by the backend. Player.currentTime() is not frame presentation time.
private final class AbrPublishedFrameTimes: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [ObjectIdentifier: (CVPixelBuffer, Double)] = [:]
  func record(_ buffer: CVPixelBuffer, time: CMTime) {
    lock.lock(); defer { lock.unlock() }
    if values.count >= 64 { values.removeAll(keepingCapacity: true) }
    let key = ObjectIdentifier(buffer)
    let seconds = CMTimeGetSeconds(time)
    values.removeValue(forKey: key)
    if time.isValid && seconds.isFinite && seconds >= 0 { values[key] = (buffer, seconds) }
  }
  func take(_ buffer: CVPixelBuffer) -> Double? {
    lock.lock(); defer { lock.unlock() }
    return values.removeValue(forKey: ObjectIdentifier(buffer))?.1
  }
}

private final class AbrTimestampVideoOutput: AVPlayerItemVideoOutput, @unchecked Sendable {
  private let times: AbrPublishedFrameTimes
  init(attributes: [String: Any], times: AbrPublishedFrameTimes) {
    self.times = times
    super.init(pixelBufferAttributes: attributes)
  }
  override func copyPixelBuffer(forItemTime itemTime: CMTime,
    itemTimeForDisplay outItemTimeForDisplay: UnsafeMutablePointer<CMTime>?) -> CVPixelBuffer? {
    var displayTime = CMTime.invalid
    let buffer = super.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime)
    outItemTimeForDisplay?.pointee = displayTime
    if let buffer { times.record(buffer, time: displayTime) }
    return buffer
  }
}

private final class DashHeldBodyServer {
  private let listener: NWListener
  private let lock = NSLock()
  private var connections: [ObjectIdentifier:NWConnection] = [:]
  private var heldConnections = Set<ObjectIdentifier>()
  private var stopped = false, closed = 0, held = 0
  private let manifest: Data, body: Data, redirect: URL, normalBodies: [String:Data]
  var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held }
  var peerClosed: Int { lock.lock(); defer { lock.unlock() }; return closed }
  func url(_ path:String) -> URL { URL(string:"http://127.0.0.1:\(listener.port!.rawValue)\(path)")! }
  init(manifest:Data,body:Data,redirect:URL,normalBodies:[String:Data] = [:]) throws {
    self.manifest = manifest; self.body = body; self.redirect = redirect; self.normalBodies = normalBodies
    listener = try NWListener(using:.tcp,on:.any)
    let ready = DispatchSemaphore(value:0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.newConnectionHandler = { [weak self] connection in
      guard let self else { connection.cancel(); return }
      self.lock.lock()
      guard !self.stopped else { self.lock.unlock(); connection.cancel(); return }
      self.connections[ObjectIdentifier(connection)] = connection
      connection.start(queue:DispatchQueue.global())
      self.lock.unlock()
      self.receiveHeader(connection,buffer:Data())
    }
    listener.start(queue:DispatchQueue(label:"yl.test.held-body"))
    guard ready.wait(timeout:.now()+3) == .success else { listener.cancel(); throw NSError(domain:"HeldBody",code:1) }
  }
  private func finish(_ connection:NWConnection,peer:Bool = false) {
    lock.lock(); let id = ObjectIdentifier(connection)
    connections.removeValue(forKey:id)
    if heldConnections.remove(id) != nil && peer { closed += 1 }
    lock.unlock(); connection.cancel()
  }
  private func receiveHeader(_ connection:NWConnection,buffer:Data) {
    connection.receive(minimumIncompleteLength:1,maximumLength:4096) { [weak self] bytes,_,complete,error in
      guard let self else { connection.cancel(); return }
      var data = buffer; if let bytes { data.append(bytes) }
      guard data.count<=16384 else { self.finish(connection); return }
      if let end = data.range(of:Data([13,10,13,10])) {
        self.respond(connection,header:String(decoding:data[..<end.upperBound],as:UTF8.self))
      } else if complete || error != nil { self.finish(connection) }
      else { self.receiveHeader(connection,buffer:data) }
    }
  }
  private func observeEOF(_ connection:NWConnection) {
    connection.receive(minimumIncompleteLength:1,maximumLength:1024) { [weak self] _,_,complete,error in
      guard let self else { connection.cancel(); return }
      if complete || error != nil { self.finish(connection,peer:true) }
      else { self.observeEOF(connection) }
    }
  }
  private func respond(_ connection:NWConnection,header:String) {
    let lines = header.components(separatedBy:"\r\n")
    let path = lines[0].split(separator:" ").dropFirst().first.map(String.init) ?? ""
    var headers: [String:String] = [:]
    for line in lines.dropFirst() {
      if let colon = line.firstIndex(of:":") { headers[String(line[..<colon]).lowercased()] = line[line.index(after:colon)...].trimmingCharacters(in:.whitespaces) }
    }
    if path == "/revoke" {
      connection.send(content:Data("HTTP/1.1 302 Found\r\nContent-Length: 0\r\nLocation: \(redirect.absoluteString)\r\nConnection: close\r\n\r\n".utf8),completion:.contentProcessed { [weak self] _ in self?.finish(connection) })
      return
    }
    let payload = path == "/movie.mpd" ? manifest : (normalBodies[path] ?? body)
    let hold = path != "/movie.mpd" && (normalBodies.isEmpty || headers["x-fixture-hold"] == "1")
    lock.lock()
    guard !stopped, connections[ObjectIdentifier(connection)] != nil else { lock.unlock(); connection.cancel(); return }
    if hold { held += 1; heldConnections.insert(ObjectIdentifier(connection)) }
    lock.unlock()
    let contentType = path == "/movie.mpd" ? "application/dash+xml" : "video/mp4"
    let response = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
    if hold {
      connection.send(content:Data(response.utf8)+payload.prefix(64),completion:.contentProcessed { _ in })
      observeEOF(connection)
    } else {
      connection.send(content:Data(response.utf8)+payload,completion:.contentProcessed { [weak self] _ in self?.finish(connection) })
    }
  }
  func close() {
    lock.lock(); stopped = true; let pending = Array(connections.values); connections.removeAll(); lock.unlock()
    listener.cancel(); pending.forEach { $0.cancel() }
  }
  deinit { close() }
}
