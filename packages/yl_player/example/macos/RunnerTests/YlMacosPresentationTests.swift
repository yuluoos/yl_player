@testable import yl_player_apple
import AppKit
import AVFAudio
import AVFoundation
import Foundation
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosPresentationTests: XCTestCase {
  @MainActor
  func testNativeReadyEvidenceSeparatesChecksAndCallback() async throws {
    guard #available(macOS 14.0, *) else { throw XCTSkip("Timed endpoint requires macOS 14") }
    let container = CALayer()
    let endpoint = try YlMacosTimedVideoEndpoint(container: container, collectDiagnostics: true,
      onFailure: { _ in XCTFail("Unexpected renderer failure") })
    defer { endpoint.retire(removingImage: true) {} }
    let layer = try XCTUnwrap(container.sublayers?.first as? AVSampleBufferDisplayLayer)
    endpoint.update(.init(positionUs: 0, hostTimeUs: YlPresentationCoordinator.hostTimeUs(), rate: 1, playing: false), generation: 1)
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let pixel = try XCTUnwrap(buffer)
    let callback = expectation(description: "native ready callback after queue flush")
    endpoint.setReadyHandler { callback.fulfill() }
    var rejected: YlFrameEnvelope?
    // Characterize the diagnostic boundary with a deliberately full, paused
    // native queue. This does not reproduce the historical playback fault.
    for index in 0..<256 {
      let frame = YlFrameEnvelope(payload: pixel, ptsUs: 10_000_000 + Int64(index) * 40_000,
        durationUs: 40_000, keyframe: true, generation: 1)
      if !endpoint.enqueue(frame) { rejected = frame; break }
    }
    let frame = try XCTUnwrap(rejected, "Paused native queue must exercise actual backpressure")
    let pending = try XCTUnwrap(endpoint.diagnostics?["readyChecks"] as? [String: Double])
    XCTAssertEqual(pending["check0Ready"], 0)
    XCTAssertGreaterThan(try XCTUnwrap(pending["check0ThreadID"]), 0)
    layer.sampleBufferRenderer.flush()
    await fulfillment(of: [callback], timeout: 3)
    XCTAssertTrue(endpoint.enqueue(frame))
    let events = try XCTUnwrap(endpoint.diagnostics?["backpressureEvents"] as? [[String: Double]])
    let event = try XCTUnwrap(events.last)
    XCTAssertEqual(event["ptsUs"], Double(frame.ptsUs))
    XCTAssertEqual(event["lastCheckReady"], 1)
    XCTAssertEqual(event["firstRejectedUptime"], event["check0Returned"])
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(event["check0Entered"]), try XCTUnwrap(event["check0Requested"]))
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(event["callbackEntered"]), try XCTUnwrap(event["registrationReturned"]))
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(event["enqueueReturnedUptime"]), try XCTUnwrap(event["lastCheckReturned"]))
    XCTAssertTrue(endpoint.diagnostics?["readyChecks"] is NSNull, "Completed evidence must detach from next frame")
  }

  @MainActor
  func testPausedTimedReattachPreservesCurrentPixel() async throws {
    guard #available(macOS 14.4, *) else { throw XCTSkip("Native pixel readback requires macOS 14.4") }
    let views = YlMacosVideoViewFactory()
    let output = YlMacosTextureOutput(textures: ApplePublicationRegistry(), nativeViews: views)
    defer { output.dispose() }
    let view = views.create(withViewIdentifier: 944, arguments: ["textureId": NSNumber(value: output.textureId)])
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
    defer { window.close() }
    var buffer: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
    let pixel = try XCTUnwrap(buffer)
    CVPixelBufferLockBaseAddress(pixel, [])
    memset(CVPixelBufferGetBaseAddress(pixel), 200, CVPixelBufferGetDataSize(pixel))
    CVPixelBufferUnlockBaseAddress(pixel, [])
    let endpoint = try XCTUnwrap(output.makeTimedVideoEndpoint())
    endpoint.update(.init(positionUs: 1_000_000, hostTimeUs: YlPresentationCoordinator.hostTimeUs(), rate: 1, playing: false), generation: 1)
    XCTAssertTrue(endpoint.enqueue(.init(payload: pixel, ptsUs: 1_000_000, durationUs: 40_000, keyframe: true, generation: 1)))
    try await Task.sleep(nanoseconds: 100_000_000)
    let container = try XCTUnwrap(view.layer)
    output.detach(container)
    try await Task.sleep(nanoseconds: 100_000_000)
    output.attach(container)
    try await Task.sleep(nanoseconds: 100_000_000)
    let layer = try XCTUnwrap(container.sublayers?.last as? AVSampleBufferDisplayLayer)
    let displayed = try XCTUnwrap(layer.sampleBufferRenderer.displayedPixelBuffer(), "Paused reattach must retain the current timed picture")
    CVPixelBufferLockBaseAddress(displayed, .readOnly)
    XCTAssertEqual(CVPixelBufferGetBaseAddress(displayed)?.assumingMemoryBound(to: UInt8.self)[1], 200)
    CVPixelBufferUnlockBaseAddress(displayed, .readOnly)
  }

  @MainActor
  func testTimedPausedPixelBelongsToCurrentGeneration() async throws {
    guard #available(macOS 14.4, *) else { throw XCTSkip("Displayed pixel readback requires macOS 14.4") }
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 64, height: 64)); view.wantsLayer = true
    let window = NSWindow(contentRect: view.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
    defer { window.close() }
    let container = try XCTUnwrap(view.layer)
    func pixel(_ green: UInt8) throws -> CVPixelBuffer {
      var buffer: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
      let result = try XCTUnwrap(buffer)
      CVPixelBufferLockBaseAddress(result, [])
      let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(result)).assumingMemoryBound(to: UInt8.self)
      for y in 0..<16 { for x in 0..<16 {
        let i = y * CVPixelBufferGetBytesPerRow(result) + 4*x
        base[i] = 0; base[i+1] = green; base[i+2] = 0; base[i+3] = 255
      } }
      CVPixelBufferUnlockBaseAddress(result, []); return result
    }
    for generation: UInt64 in [1, 2] {
      let endpoint = try YlMacosTimedVideoEndpoint(container: container, onFailure: { _ in XCTFail("Native pixel failure") })
      let layer = try XCTUnwrap(container.sublayers?.last as? AVSampleBufferDisplayLayer)
      let pts: Int64 = generation == 1 ? 0 : 2_000_000
      endpoint.update(.init(positionUs: pts, hostTimeUs: YlPresentationCoordinator.hostTimeUs(), rate: 1, playing: false), generation: generation)
      let shade: UInt8 = generation == 1 ? 32 : 200
      XCTAssertTrue(endpoint.enqueue(.init(payload: try pixel(shade), ptsUs: pts, durationUs: 40_000, keyframe: true, generation: generation)))
      if generation == 2 {
        XCTAssertFalse(endpoint.enqueue(.init(payload: try pixel(32), ptsUs: 0, durationUs: 40_000, keyframe: true, generation: 1)))
      }
      try await Task.sleep(nanoseconds: 200_000_000)
      let displayed = try XCTUnwrap(layer.sampleBufferRenderer.displayedPixelBuffer())
      XCTAssertEqual(CVPixelBufferGetPixelFormatType(displayed), kCVPixelFormatType_32BGRA)
      CVPixelBufferLockBaseAddress(displayed, .readOnly)
      let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(displayed)).assumingMemoryBound(to: UInt8.self)
      XCTAssertEqual(Double(bytes[1]), Double(shade), accuracy: 2)
      CVPixelBufferUnlockBaseAddress(displayed, .readOnly)
      let retired = expectation(description: "pixel epoch retired")
      endpoint.retire(removingImage: true) { retired.fulfill() }
      await fulfillment(of: [retired], timeout: 2)
      XCTAssertTrue(container.sublayers?.isEmpty ?? true)
    }
  }

  @MainActor
  func testContinuousClockObservationsDoNotAnnounceTimeJumps() async throws {
    guard #available(macOS 14.0, *) else { throw XCTSkip("Timed endpoint requires macOS 14") }
    let container = CALayer()
    let endpoint = try YlMacosTimedVideoEndpoint(container: container, onFailure: { _ in XCTFail("Clock failure") })
    let layer = try XCTUnwrap(container.sublayers?.first as? AVSampleBufferDisplayLayer)
    let base = try XCTUnwrap(layer.controlTimebase)
    let host = YlPresentationCoordinator.hostTimeUs()
    endpoint.update(.init(positionUs: 1_000_000, hostTimeUs: host, rate: 1, playing: true), generation: 1)
    CMTimebaseNotificationBarrier(base)
    let lock = NSLock()
    var jumps = 0
    let observer = NotificationCenter.default.addObserver(
      forName: NSNotification.Name(kCMTimebaseNotification_TimeJumped as String), object: base, queue: nil
    ) { _ in lock.withLock { jumps += 1 } }
    defer { NotificationCenter.default.removeObserver(observer); endpoint.retire(removingImage: true) {} }
    for index in 1...20 {
      let now = YlPresentationCoordinator.hostTimeUs()
      // Paired readings represent one continuous timeline with sub-ms source jitter.
      endpoint.update(.init(positionUs: 1_000_000 + now - host + (index.isMultiple(of: 2) ? 200 : -200),
        hostTimeUs: now, rate: 1, playing: true), generation: 1)
    }
    CMTimebaseNotificationBarrier(base)
    XCTAssertEqual(lock.withLock { jumps }, 0, "Polling a continuous audio clock must not repeatedly announce a discontinuity to the renderer")
    let now = YlPresentationCoordinator.hostTimeUs()
    XCTAssertEqual(CMTimeGetSeconds(CMTimebaseGetTime(base)), 1 + Double(now - host) / 1_000_000, accuracy: 0.001)
    // Every increment is below tolerance, but their accumulated phase exceeds
    // it. Comparing only consecutive observations would incorrectly ignore all.
    for step in 1...4 {
      let observedHost = YlPresentationCoordinator.hostTimeUs()
      endpoint.update(.init(positionUs: 1_000_000 + observedHost - host + Int64(step * 600),
        hostTimeUs: observedHost, rate: 1, playing: true), generation: 1)
    }
    let accumulatedHost = YlPresentationCoordinator.hostTimeUs()
    XCTAssertEqual(CMTimeGetSeconds(CMTimebaseGetTime(base)),
      1.0024 + Double(accumulatedHost - host) / 1_000_000, accuracy: 0.001)
    endpoint.update(.init(positionUs: 1_010_000 + now - host, hostTimeUs: now, rate: 1, playing: true), generation: 1)
    CMTimebaseNotificationBarrier(base)
    XCTAssertGreaterThan(lock.withLock { jumps }, 0, "Accumulated drift must be corrected against the applied anchor")
    let checkHost = YlPresentationCoordinator.hostTimeUs()
    XCTAssertEqual(CMTimeGetSeconds(CMTimebaseGetTime(base)), 1.01 + Double(checkHost - host) / 1_000_000, accuracy: 0.001)
    let beforePause = lock.withLock { jumps }
    endpoint.update(.init(positionUs: 2_000_000, hostTimeUs: now, rate: 1, playing: false), generation: 1)
    CMTimebaseNotificationBarrier(base)
    XCTAssertGreaterThan(lock.withLock { jumps }, beforePause, "A real control discontinuity must still reach the native timebase")
    XCTAssertEqual(CMTimebaseGetRate(base), 0)
    XCTAssertEqual(CMTimeGetSeconds(CMTimebaseGetTime(base)), 2, accuracy: 0.000001)
  }

  @MainActor
  func testRetiredTimedSampleDoesNotWaitForCallerAutoreleasePool() async throws {
    guard #available(macOS 14.0, *) else { throw XCTSkip("Timed endpoint requires macOS 14") }
    let container = CALayer()
    let endpoint = try YlMacosTimedVideoEndpoint(container: container, collectDiagnostics: true, onFailure: { _ in XCTFail("Sample failure") })
    endpoint.update(.init(positionUs: 0, hostTimeUs: YlPresentationCoordinator.hostTimeUs(), rate: 1, playing: false), generation: 1)
    let ledger = YlManagedBufferLedger()
    let submitted = expectation(description: "sample submitted")
    let release = DispatchSemaphore(value: 0)
    let done = expectation(description: "caller pool drained")
    // This helper's strong frame/token locals die before the caller stays idle.
    @Sendable func submit() {
      var pixel: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
      guard let pixel, let token = ledger.reserve(category: .queuedVideoFrames, bytes: 1024, generation: 1) else {
        XCTFail("Could not allocate sample"); return
      }
      XCTAssertTrue(endpoint.enqueue(.init(reservation: token, payload: pixel, ptsUs: 0, durationUs: 40_000, keyframe: true, generation: 1)))
    }
    DispatchQueue(label: "test.timed.caller-pool").async {
      autoreleasepool {
        submit(); submitted.fulfill()
        _ = release.wait(timeout: .now() + 10)
      }
      done.fulfill()
    }
    await fulfillment(of: [submitted], timeout: 2)
    let retired = expectation(description: "native flush completed")
    endpoint.retire(removingImage: true) { retired.fulfill() }
    await fulfillment(of: [retired], timeout: 2)
    try await AppleHostCharacterizations.waitFor({ ledger.snapshot.currentBytes == 0 }, timeout: 0.5)
    let bytesBeforeCallerPoolDrain = ledger.snapshot.currentBytes
    release.signal()
    await fulfillment(of: [done], timeout: 2)
    XCTAssertEqual(bytesBeforeCallerPoolDrain, 0, "A flushed sample must not stay charged until an unrelated caller pool drains")
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }

  @MainActor
  func testNativeTimedEndpointFreezesAndRetires() async throws {
    guard #available(macOS 14.0, *) else { throw XCTSkip("Timed endpoint requires macOS 14") }
    let container = CALayer(); container.bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
    let endpoint = try YlMacosTimedVideoEndpoint(container: container, onFailure: { _ in XCTFail("Unexpected native renderer error") })
    let layer = try XCTUnwrap(container.sublayers?.first as? AVSampleBufferDisplayLayer)
    let timebase = try XCTUnwrap(layer.controlTimebase)
    XCTAssertEqual(CMTimebaseGetRate(timebase), 0)
    let now = YlPresentationCoordinator.hostTimeUs()
    endpoint.update(.init(positionUs: 1_000_000, hostTimeUs: now, rate: 2, playing: true), generation: 9)
    XCTAssertEqual(CMTimebaseGetRate(timebase), 2)
    endpoint.update(.init(positionUs: 1_200_000, hostTimeUs: now, rate: 2, playing: false), generation: 9)
    XCTAssertEqual(CMTimebaseGetRate(timebase), 0)
    XCTAssertEqual(CMTimeGetSeconds(CMTimebaseGetTime(timebase)), 1.2, accuracy: 0.001)
    XCTAssertFalse(endpoint.enqueue(.init(payload: NSObject(), ptsUs: 1, durationUs: 1, keyframe: true, generation: 8)), "Stale generation is rejected before interpreting the payload")
    let retired = expectation(description: "native layer retired")
    endpoint.retire(removingImage: true) { retired.fulfill() }
    XCTAssertTrue(endpoint.isRetired)
    await fulfillment(of: [retired], timeout: 2)
    XCTAssertTrue(container.sublayers?.isEmpty ?? true)
    XCTAssertFalse(endpoint.enqueue(.init(payload: NSObject(), ptsUs: 1, durationUs: 1, keyframe: true, generation: 9)))
  }



  func testCandidatePositionAndWorkerNeverReadNativeAudioSynchronously() {
    let lock = NSLock(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var legacyReads = 0
    let clock = YlMediaClock(audioTime: { lock.withLock { legacyReads += 1 }; return nil })
    clock.enableIsolatedAudioClock(read: { _ in
      entered.signal(); _ = release.wait(timeout: .now() + 2); return .waiting
    }, generation: 1)
    clock.seek(to: 1_000_000); clock.play(atHostTimeUs: YlPresentationCoordinator.hostTimeUs())
    defer { clock.stopIsolatedAudioClock(); release.signal() }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    _ = clock.position(atHostTimeUs: YlPresentationCoordinator.hostTimeUs())
    _ = clock.presentationSnapshot(atHostTimeUs: YlPresentationCoordinator.hostTimeUs())
    XCTAssertEqual(lock.withLock { legacyReads }, 0)
    XCTAssertNotNil(clock.isolatedAudioClockStatistics)
  }

  func testCandidatePauseRevokesBeforeNativePauseCompletes() {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let clock = YlMediaClock()
    clock.enableIsolatedAudioClock(read: { _ in
      entered.signal(); _ = release.wait(timeout: .now() + 2)
      return .running(.init(generation: 1, positionUs: 1_000_000,
        hostTimeUs: YlPresentationCoordinator.hostTimeUs(), lowerBoundUs: 0, upperBoundUs: 2_000_000, rate: 1))
    }, generation: 1)
    let now = YlPresentationCoordinator.hostTimeUs()
    clock.seek(to: 700_000); clock.play(atHostTimeUs: now)
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    clock.invalidateIsolatedAudioClock()
    XCTAssertFalse(clock.presentationSnapshot(atHostTimeUs: now).playing)
    clock.pause(atHostTimeUs: now)
    release.signal()
    XCTAssertFalse(clock.presentationSnapshot(atHostTimeUs: now + 50_000).playing)
    XCTAssertEqual(clock.position(atHostTimeUs: now + 50_000), 700_000)
    clock.stopIsolatedAudioClock()
  }

  func testCandidateClockEOFAndSilenceRemainDistinct() {
    let lock = NSLock(), read = DispatchSemaphore(value: 0)
    let now = YlPresentationCoordinator.hostTimeUs()
    var value = YlAudioClockObservation.silence(.init(generation: 1, positionUs: 1_250_000,
      hostTimeUs: now, lowerBoundUs: 1_250_000, upperBoundUs: 1_250_000, rate: 1))
    let clock = YlMediaClock()
    clock.enableIsolatedAudioClock(read: { _ in
      let result = lock.withLock { value }; read.signal(); return result
    }, generation: 1)
    defer { clock.stopIsolatedAudioClock() }
    clock.play(atHostTimeUs: now)
    XCTAssertEqual(read.wait(timeout: .now() + 1), .success)
    // Wait for publication rather than assuming the callback already returned.
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while (clock.isolatedAudioClockStatistics?.samples ?? 0) < 1 && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertEqual(clock.position(atHostTimeUs: now + 50_000), 1_250_000)
    lock.withLock { value = .waiting }
    XCTAssertFalse(clock.presentationSnapshot(atHostTimeUs: now + 200_000).playing)
    lock.withLock { value = .ended(positionUs: 1_500_000, hostTimeUs: now) }
    let after = (clock.isolatedAudioClockStatistics?.samples ?? 0)
    let end = ProcessInfo.processInfo.systemUptime + 1
    while (clock.isolatedAudioClockStatistics?.samples ?? 0) <= after && ProcessInfo.processInfo.systemUptime < end { Thread.sleep(forTimeInterval: 0.001) }
    XCTAssertEqual(clock.position(atHostTimeUs: now + 500_000), 2_000_000)
  }

  private final class AudioClockProbe {
    let lock = NSLock(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    var now: Int64 = 1_000_000
    var sourceHost: Int64 = 1_000_000
    var block = false
    func host() -> Int64 { lock.withLock { now } }
    func setNow(_ value: Int64) { lock.withLock { now = value } }
    func read(_ generation: UInt64) -> YlAudioClockObservation {
      let values = lock.withLock { (block, sourceHost) }
      if values.0 { entered.signal(); _ = release.wait(timeout: .now() + 2) }
      return .running(.init(generation: generation, positionUs: 1_000_000,
        hostTimeUs: values.1, lowerBoundUs: 0, upperBoundUs: 2_000_000, rate: 1))
    }
  }

  func testIsolatedClockSuppliesWhileAudioReadIsBlocked() {
    let probe = AudioClockProbe(), queue = DispatchQueue(label: "test.isolated.block")
    let clock = YlIsolatedAudioClock(read: probe.read, hostTimeUs: probe.host, queue: queue)
    clock.configure(generation: 1, positionUs: 1_000_000, rate: 1, playing: true)
    queue.sync {}
    probe.lock.withLock { probe.block = true }
    defer { clock.stop(); probe.release.signal(); queue.sync {} }
    XCTAssertEqual(probe.entered.wait(timeout: .now() + 1), .success)
    let snapshot = clock.snapshot(atHostTimeUs: 1_050_000)
    XCTAssertTrue(snapshot.playing); XCTAssertEqual(snapshot.positionUs, 1_050_000)
    let scheduler = YlFrameScheduler(), output = PumpOutput()
    XCTAssertTrue(scheduler.enqueue(.init(payload: NSObject(), ptsUs: 1_070_000,
      durationUs: 40_000, keyframe: true, generation: 1)))
    let worker = DispatchQueue(label: "test.isolated.video")
    let pump = YlTimedVideoPump(scheduler: scheduler, endpoint: output,
      clockSnapshot: { clock.snapshot(atHostTimeUs: 1_050_000) }, generation: 1, queue: worker)
    pump.synchronize(); worker.sync {}; pump.stop {}; worker.sync {}
    XCTAssertEqual(output.pts, [1_070_000])
  }

  func testIsolatedClockExpiresWithoutHostFallback() {
    let probe = AudioClockProbe(), queue = DispatchQueue(label: "test.isolated.expire")
    let clock = YlIsolatedAudioClock(read: probe.read, hostTimeUs: probe.host, queue: queue)
    defer { clock.stop() }
    clock.configure(generation: 1, positionUs: 1_000_000, rate: 1, playing: true); queue.sync {}
    XCTAssertEqual(clock.snapshot(atHostTimeUs: 1_050_000).positionUs, 1_050_000)
    let expired = clock.snapshot(atHostTimeUs: 1_100_001)
    XCTAssertFalse(expired.playing)
    XCTAssertEqual(clock.snapshot(atHostTimeUs: 2_000_000).positionUs, expired.positionUs)
    XCTAssertEqual(clock.statistics.staleEvents, 1)
    clock.configure(generation: 2, positionUs: 1_000_000, rate: 1, playing: true); queue.sync {}
    XCTAssertTrue(clock.snapshot(atHostTimeUs: 1_000_000).playing)
    XCTAssertEqual(clock.statistics.staleEvents, 1)
  }

  func testRepeatedOldObservationCannotRenewFreshness() {
    let probe = AudioClockProbe(), queue = DispatchQueue(label: "test.isolated.old")
    let clock = YlIsolatedAudioClock(read: probe.read, hostTimeUs: probe.host, queue: queue)
    defer { clock.stop() }
    probe.setNow(1_200_000)
    clock.configure(generation: 1, positionUs: 1_000_000, rate: 1, playing: true); queue.sync {}
    XCTAssertFalse(clock.snapshot(atHostTimeUs: 1_200_000).playing)
    XCTAssertEqual(clock.statistics.staleEvents, 1)
    probe.lock.withLock { probe.sourceHost = 1_020_000; probe.now = 1_000_000 }
    clock.configure(generation: 2, positionUs: 0, rate: 1, playing: true); queue.sync {}
    XCTAssertEqual(clock.snapshot(atHostTimeUs: 1_000_000).positionUs, 980_000)
  }

  func testBlockedSampleCannotSurviveControlVersionChange() {
    for operation in 0..<4 {
      let probe = AudioClockProbe(), queue = DispatchQueue(label: "test.isolated.control")
      probe.block = true
      let clock = YlIsolatedAudioClock(read: probe.read, hostTimeUs: probe.host, queue: queue)
      clock.configure(generation: 1, positionUs: 1_000_000, rate: 1, playing: true)
      XCTAssertEqual(probe.entered.wait(timeout: .now() + 1), .success)
      switch operation {
      case 0: clock.configure(generation: 1, positionUs: 700_000, rate: 1, playing: false)
      case 1: for g: UInt64 in 2...101 { clock.configure(generation: g, positionUs: 700_000, rate: 1, playing: false) }
      case 2: clock.configure(generation: 1, positionUs: 700_000, rate: 2, playing: false)
      default: clock.stop()
      }
      XCTAssertFalse(clock.snapshot(atHostTimeUs: 1_010_000).playing)
      probe.release.signal(); queue.sync {}
      XCTAssertFalse(clock.snapshot(atHostTimeUs: 1_010_000).playing)
      XCTAssertGreaterThanOrEqual(clock.statistics.rejectedObservations, 1)
      if operation < 3 { XCTAssertEqual(clock.snapshot(atHostTimeUs: 1_010_000).positionUs, 700_000) }
      clock.stop()
    }
  }

  private final class PumpOutput: YlTimedVideoEndpoint {
    let lock = NSLock()
    var ready = true
    var onEnqueue: (() -> Void)?
    var onReady: (() -> Void)?
    func setReadyHandler(_ handler: @escaping () -> Void) { onReady = handler }
    var closed = false
    private var values: [Int64] = []
    var pts: [Int64] { lock.withLock { values } }
    func update(_ snapshot: YlPresentationClockSnapshot, generation: UInt64) {}
    func enqueue(_ frame: YlFrameEnvelope) -> Bool {
      onEnqueue?()
      return lock.withLock { guard ready && !closed else { return false }; values.append(frame.ptsUs); return true }
    }
    func retire(removingImage: Bool, completion: @escaping () -> Void) {
      lock.withLock { closed = true }; completion()
    }
  }
  private final class TimedClockBox {
    let lock = NSLock()
    var value = YlPresentationClockSnapshot(positionUs: 0, hostTimeUs: 0, rate: 1, playing: false)
    func snapshot() -> YlPresentationClockSnapshot { lock.withLock { value } }
    func set(_ position: Int64, playing: Bool) {
      lock.withLock { value = .init(positionUs: position, hostTimeUs: position, rate: 1, playing: playing) }
    }
  }

  func testTimedReadyNotificationResumesHeldFrameAndCoalesces() throws {
    let scheduler = YlFrameScheduler(), raw = PumpOutput(), clock = TimedClockBox()
    let endpoint = YlTimedVideoLeaseEndpoint(raw)
    let queue = DispatchQueue(label: "test.timed.ready-wake")
    let readsLock = NSLock(); var reads = 0
    raw.ready = false; clock.set(0, playing: true)
    XCTAssertTrue(scheduler.enqueue(.init(payload: NSObject(), ptsUs: 40_000,
      durationUs: 40_000, keyframe: true, generation: 1)))
    // No timer can rescue missing native readiness notifications in this test.
    let pump = YlTimedVideoPump(scheduler: scheduler, endpoint: endpoint, clockSnapshot: {
      readsLock.withLock { reads += 1 }; return clock.snapshot()
    }, generation: 1, pollInterval: .seconds(3600), queue: queue)
    defer { pump.stop {}; queue.sync {} }
    pump.synchronize(); queue.sync {}
    XCTAssertTrue(pump.hasPendingPresentation); XCTAssertTrue(raw.pts.isEmpty)
    let ready = try XCTUnwrap(raw.onReady, "Native readiness must reach the worker through its revocable lease")
    let before = readsLock.withLock { reads }
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    queue.async { entered.signal(); release.wait() }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    raw.lock.withLock { raw.ready = true }
    for _ in 0..<1000 { ready() }
    release.signal(); queue.sync {}
    XCTAssertEqual(raw.pts, [40_000], "Ready recovery must submit without waiting for timer or UI")
    XCTAssertEqual(readsLock.withLock { reads }, before + 1, "Ready bursts must coalesce into one asynchronous tick")
    pump.stop {}; queue.sync {}
    let stoppedReads = readsLock.withLock { reads }
    ready(); queue.sync {}
    XCTAssertEqual(readsLock.withLock { reads }, stoppedReads, "A retired callback cannot wake the old epoch")
  }

  func testTimedDiagnosticsSeparateClockReadFromIdleGap() throws {
    let queue = DispatchQueue(label: "test.timed.diagnostic")
    let pump = YlTimedVideoPump(scheduler: YlFrameScheduler(), endpoint: PumpOutput(), clockSnapshot: {
      Thread.sleep(forTimeInterval: 0.12)
      return .init(positionUs: 0, hostTimeUs: 0, rate: 1, playing: true)
    }, generation: 1, collectDiagnostics: true, queue: queue)
    pump.synchronize(); queue.sync {}
    pump.stop {}; queue.sync {}
    let diagnostic = try XCTUnwrap(pump.statistics.diagnostics)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(diagnostic["clockSeconds"] as? Double), 0.1)
    XCTAssertLessThan(try XCTUnwrap(diagnostic["updateSeconds"] as? Double), 0.05)
    XCTAssertFalse(try XCTUnwrap(diagnostic["slowTicks"] as? [[String: Double]]).isEmpty)
    let disabled = YlTimedVideoPump(scheduler: YlFrameScheduler(), endpoint: PumpOutput(),
      clockSnapshot: { .init(positionUs: 0, hostTimeUs: 0, rate: 1, playing: false) }, generation: 1, queue: queue)
    disabled.synchronize(); queue.sync {}; disabled.stop {}; queue.sync {}
    XCTAssertNil(disabled.statistics.diagnostics)
  }

  func testTimedPendingCoversInFlightEnqueue() {
    let scheduler = YlFrameScheduler(), endpoint = PumpOutput(), clock = TimedClockBox()
    let queue = DispatchQueue(label: "test.timed.eof-race")
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    endpoint.onEnqueue = { entered.signal(); _ = release.wait(timeout: .now() + 2) }
    clock.set(0, playing: true)
    XCTAssertTrue(scheduler.enqueue(.init(payload: NSObject(), ptsUs: 40_000, durationUs: 40_000, keyframe: true, generation: 1)))
    let pump = YlTimedVideoPump(scheduler: scheduler, endpoint: endpoint, clockSnapshot: clock.snapshot, generation: 1, queue: queue)
    pump.synchronize()
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    XCTAssertTrue(scheduler.pendingPTS.isEmpty)
    XCTAssertTrue(pump.hasPendingPresentation, "EOF must see the frame between scheduler removal and native enqueue completion")
    release.signal(); queue.sync {}; pump.stop {}; queue.sync {}
  }

  func testTimedBackpressurePreservesFrameOutsideRevisedHorizon() {
    let scheduler = YlFrameScheduler(), endpoint = PumpOutput(), clock = TimedClockBox()
    let queue = DispatchQueue(label: "test.timed.revised-horizon")
    endpoint.ready = false; clock.set(100_000, playing: true)
    XCTAssertTrue(scheduler.enqueue(.init(payload: NSObject(), ptsUs: 140_000, durationUs: 40_000, keyframe: true, generation: 1)))
    let pump = YlTimedVideoPump(scheduler: scheduler, endpoint: endpoint, clockSnapshot: clock.snapshot, generation: 1, queue: queue)
    defer { pump.stop {}; queue.sync {} }
    pump.synchronize(); queue.sync {}
    XCTAssertTrue(pump.hasPendingPresentation)
    // A backward audio clock observation shrinks the lead horizon around a held frame.
    clock.set(0, playing: true); pump.synchronize(); queue.sync {}
    XCTAssertTrue(pump.hasPendingPresentation)
    XCTAssertEqual(pump.statistics.rejected, 0)
    endpoint.lock.withLock { endpoint.ready = true }
    clock.set(100_000, playing: true); pump.synchronize(); queue.sync {}
    XCTAssertEqual(endpoint.pts, [140_000])
  }

  func testTimedPumpStopsAdmissionOnPause() {
    let scheduler = YlFrameScheduler(), endpoint = PumpOutput(), clock = TimedClockBox()
    let queue = DispatchQueue(label: "test.timed.pause")
    for pts: Int64 in [0, 40_000, 80_000] {
      XCTAssertTrue(scheduler.enqueue(.init(payload: NSObject(), ptsUs: pts, durationUs: 40_000, keyframe: true, generation: 1)))
    }
    let pump = YlTimedVideoPump(scheduler: scheduler, endpoint: endpoint, clockSnapshot: clock.snapshot, generation: 1, queue: queue)
    defer { pump.stop {}; queue.sync {} }
    pump.synchronize(); queue.sync {}
    XCTAssertTrue(endpoint.pts.isEmpty)
    clock.set(0, playing: true); pump.synchronize(); queue.sync {}
    XCTAssertEqual(endpoint.pts, [0, 40_000])
    clock.set(10_000, playing: false); pump.synchronize(); queue.sync {}
    XCTAssertEqual(endpoint.pts, [0, 40_000])
    clock.set(100_000, playing: true); pump.synchronize(); queue.sync {}
    XCTAssertEqual(endpoint.pts, [0, 40_000, 80_000])
  }

  func testTimedPumpCloseFencesReadyCallback() {
    let scheduler = YlFrameScheduler(), endpoint = PumpOutput(), clock = TimedClockBox()
    endpoint.ready = false; clock.set(0, playing: true)
    let queue = DispatchQueue(label: "test.timed.close")
    var payload: NSObject? = NSObject(); weak var retained = payload
    XCTAssertTrue(scheduler.enqueue(.init(payload: payload!, ptsUs: 0, durationUs: 1, keyframe: true, generation: 1)))
    payload = nil
    let pump = YlTimedVideoPump(scheduler: scheduler, endpoint: endpoint, clockSnapshot: clock.snapshot, generation: 1, queue: queue)
    pump.synchronize(); queue.sync {}
    XCTAssertTrue(pump.hasPendingPresentation); XCTAssertNotNil(retained)
    pump.stop {}; queue.sync {}
    endpoint.lock.withLock { endpoint.ready = true }
    pump.synchronize(); queue.sync {}
    XCTAssertTrue(endpoint.pts.isEmpty); XCTAssertFalse(pump.hasPendingPresentation)
    XCTAssertNil(retained, "Closing releases a frame waiting for native capacity")
    pump.stop {}; queue.sync {}
  }

  func testTimedEOFKeepsFutureVideoPending() {
    let scheduler = YlFrameScheduler(), endpoint = PumpOutput(), clock = TimedClockBox()
    let queue = DispatchQueue(label: "test.timed.eof")
    clock.set(0, playing: true)
    XCTAssertTrue(scheduler.enqueue(.init(payload: NSObject(), ptsUs: 40_000, durationUs: 40_000, keyframe: true, generation: 1)))
    let pump = YlTimedVideoPump(scheduler: scheduler, endpoint: endpoint, clockSnapshot: clock.snapshot, generation: 1, queue: queue)
    defer { pump.stop {}; queue.sync {} }
    pump.synchronize(); queue.sync {}
    XCTAssertTrue(scheduler.pendingPTS.isEmpty); XCTAssertTrue(pump.hasPendingPresentation)
    clock.set(50_000, playing: true); pump.synchronize(); queue.sync {}
    XCTAssertTrue(pump.hasPendingPresentation, "Last frame duration remains pending after its PTS")
    clock.set(80_000, playing: true); pump.synchronize(); queue.sync {}
    XCTAssertFalse(pump.hasPendingPresentation)
  }

  func testTimedSamplesCarryPTSWithoutImmediateDisplay() throws {
    var pixel: CVPixelBuffer?
    XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
    var token: NSObject? = NSObject(); weak var held = token
    var sample: CMSampleBuffer? = try YlSampleBufferVideoRenderer.makeSample(try XCTUnwrap(pixel), retaining: token,
      timing: .init(duration: CMTime(value: 40_000, timescale: 1_000_000), presentationTimeStamp: CMTime(value: 7_000_000, timescale: 1_000_000), decodeTimeStamp: .invalid))
    token = nil
    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(try XCTUnwrap(sample)), CMTime(value: 7, timescale: 1))
    XCTAssertEqual(CMSampleBufferGetDuration(try XCTUnwrap(sample)), CMTime(value: 4, timescale: 100))
    let attachments = CMSampleBufferGetSampleAttachmentsArray(try XCTUnwrap(sample), createIfNecessary: false) as? [NSDictionary]
    XCTAssertNotEqual(attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool, true)
    XCTAssertNotNil(held)
    sample = nil
    XCTAssertNil(held)
  }

  private final class RecordingTimedEndpoint: YlTimedVideoEndpoint {
    var pts: [Int64] = []
    var retirement: (() -> Void)?
    var beforeEnqueue: (() -> Void)?
    func update(_ snapshot: YlPresentationClockSnapshot, generation: UInt64) {}
    func enqueue(_ frame: YlFrameEnvelope) -> Bool {
      beforeEnqueue?(); pts.append(frame.ptsUs); return true
    }
    func retire(removingImage: Bool, completion: @escaping () -> Void) { retirement = completion }
  }
  private final class RecordingTimedOutput: YlTextureOutput, YlTimedVideoOutput {
    var supportsTimedVideo = true
    let textureId: Int64 = 91
    var endpoints: [RecordingTimedEndpoint] = []
    func makeTimedVideoEndpoint() -> (any YlTimedVideoEndpoint)? {
      let endpoint = RecordingTimedEndpoint(); endpoints.append(endpoint); return endpoint
    }
    func publish(_ pixelBuffer: CVPixelBuffer?) {}
    func resize(width: Int, height: Int) {}
    func clear() {}
    func dispose() {}
  }

  private final class CandidatePresentationSink: YlPresentationOutput {
    var presentationGeneration: UInt64 = 1
    var allowsBoundedPresentation = false
    func acceptsPresentationFrame(generation: UInt64) -> Bool { generation == presentationGeneration }
    func didAcceptPresentationFrame(generation: UInt64) {}
    func didPublishFirstPresentationFrame() {}
    func presentationDidTick(atHostTimeUs: Int64) {}
    func emitPresentationDelta() {}
  }

  @MainActor
  func testTimedDecodeDoesNotRetainFrameInLegacyMainQueueNotice() throws {
    let texture = RecordingTimedOutput(), sink = CandidatePresentationSink(), scheduler = YlFrameScheduler()
    var tick: (() -> Void)?
    let services = YlPlatformServices(platform: .macos, textureOutput: texture,
      makeDisplayDriver: { tick = $0; return AppleTestDisplay() })
    let coordinator = YlPresentationCoordinator(services: services, lock: NSLock(), openedAt: 0,
      positionEventIntervalMs: 100, scheduler: scheduler)
    coordinator.output = sink
    coordinator.configureClock(nil, audioTime: { nil })
    coordinator.configureTimedCandidate(enabled: true, requiresAudioAnchor: false)
    coordinator.flushFrames(generation: 1)
    coordinator.play(atHostTimeUs: YlPresentationCoordinator.hostTimeUs())
    coordinator.installDisplayLink(paused: false)
    try XCTUnwrap(tick)()
    XCTAssertNotNil(coordinator.timedVideoStatistics)
    let ledger = YlManagedBufferLedger(), done = DispatchSemaphore(value: 0)
    @Sendable func decodeOneFrame() {
      var pixel: CVPixelBuffer?
      XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixel), kCVReturnSuccess)
      guard let pixel, let token = ledger.reserve(category: .queuedVideoFrames, bytes: 1024, generation: 1) else {
        XCTFail("No decoded frame"); return
      }
      coordinator.receive(.init(pixelBuffer: pixel, ptsUs: 10_000_000, durationUs: 40_000,
        keyframe: true, generation: 1, ownershipToken: nil, reservation: token))
    }
    DispatchQueue.global().async {
      decodeOneFrame()
      // The far-future frame never entered the timed endpoint. The scheduler
      // relinquishes it, while this test deliberately keeps main unavailable.
      scheduler.dispose()
      done.signal()
    }
    XCTAssertEqual(done.wait(timeout: .now() + 2), .success)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0, "A selected timed surface must not retain decoded media in an unused legacy UI notice")
    sink.presentationGeneration = 2
    coordinator.retireDisplay(); coordinator.disposeFrames()
    texture.endpoints.forEach { $0.retirement?() }
  }

  func testUnsupportedTimedOutputKeepsLegacyAudioClock() {
    let output = RecordingTimedOutput(); output.supportsTimedVideo = false
    let services = YlPlatformServices(platform: .macos, textureOutput: output,
      makeDisplayDriver: { _ in fatalError("Clock-only test must not install display") })
    let coordinator = YlPresentationCoordinator(services: services, lock: NSLock(), openedAt: 0, positionEventIntervalMs: 100)
    var legacyReads = 0
    coordinator.configureClock(nil, audioTime: { legacyReads += 1; return nil })
    coordinator.configureTimedCandidate(enabled: true, requiresAudioAnchor: true)
    XCTAssertFalse(coordinator.configureIsolatedAudioClock(generation: 1, read: { _ in
      XCTFail("Unsupported output must not sample a candidate clock"); return .waiting
    }))
    coordinator.play(atHostTimeUs: 1000)
    XCTAssertEqual(coordinator.position(atHostTimeUs: 2000), 1000)
    XCTAssertGreaterThan(legacyReads, 0)
    XCTAssertNil(coordinator.isolatedAudioClockStatistics)
    coordinator.disposeFrames()
  }

  @MainActor
  func testTimedLeaseRejectsBeforeCommitAndAfterReplacement() async throws {
    let output = RecordingTimedOutput()
    // Use one real owner throughout the lifecycle; the output only records the system boundary.
    var publications: [String] = []
    let actual = YlAppleTextureOwner(output: output, onFrame: { publications.append($0.sessionId) })
    defer { actual.dispose() }
    let a = actual.makeLease(identity: .init(sessionId: "a", loadRequestId: "a"))
    XCTAssertNil(a.makeTimedVideoEndpoint())
    actual.commit(a)
    let endpoint = try XCTUnwrap(a.makeTimedVideoEndpoint())
    let raw = try XCTUnwrap(output.endpoints.last)
    let frame = YlFrameEnvelope(payload: NSObject(), ptsUs: 1, durationUs: 1, keyframe: true, generation: 1)
    XCTAssertTrue(endpoint.enqueue(frame))
    await Task.yield()
    XCTAssertEqual(publications, ["a"], "Timed publication must reach the real host first-frame gate")
    let b = actual.makeLease(identity: .init(sessionId: "b", loadRequestId: "b"))
    actual.commit(b)
    XCTAssertFalse(endpoint.enqueue(frame))
    XCTAssertEqual(raw.pts, [1])
    XCTAssertNil(b.makeTimedVideoEndpoint(), "New output must wait for the old native flush")
    try XCTUnwrap(raw.retirement)()
    await Task.yield()
    let replacement = try XCTUnwrap(b.makeTimedVideoEndpoint())
    XCTAssertTrue(replacement.enqueue(frame))
    actual.dispose(); actual.dispose()
    XCTAssertFalse(replacement.enqueue(frame))
    output.endpoints.last?.retirement?()
  }

  @MainActor
  func testLateTimedFlushCannotClearNewLease() async throws {
    let output = RecordingTimedOutput()
    let actual = YlAppleTextureOwner(output: output, onFrame: { _ in })
    defer { actual.dispose() }
    let a = actual.makeLease(identity: .init(sessionId: "a", loadRequestId: "a")); actual.commit(a)
    _ = try XCTUnwrap(a.makeTimedVideoEndpoint()); let first = try XCTUnwrap(output.endpoints.last)
    a.clear()
    let b = actual.makeLease(identity: .init(sessionId: "b", loadRequestId: "b")); actual.commit(b)
    let c = actual.makeLease(identity: .init(sessionId: "c", loadRequestId: "c")); actual.commit(c)
    XCTAssertNil(b.makeTimedVideoEndpoint()); XCTAssertNil(c.makeTimedVideoEndpoint())
    let oldFlush = try XCTUnwrap(first.retirement); oldFlush()
    await Task.yield()
    let latest = try XCTUnwrap(c.makeTimedVideoEndpoint())
    oldFlush() // A duplicate system completion must not reopen any old permission.
    XCTAssertNil(a.makeTimedVideoEndpoint()); XCTAssertNil(b.makeTimedVideoEndpoint())
    XCTAssertTrue(latest.enqueue(.init(payload: NSObject(), ptsUs: 2, durationUs: 1, keyframe: true, generation: 2)))
    actual.dispose(); output.endpoints.last?.retirement?()
  }

  @MainActor
  func testTimedLeaseCloseDoesNotWaitUnderSessionLock() async throws {
    let output = RecordingTimedOutput()
    let owner = YlAppleTextureOwner(output: output, onFrame: { _ in })
    let a = owner.makeLease(identity: .init(sessionId: "a", loadRequestId: "a")); owner.commit(a)
    let endpoint = try XCTUnwrap(a.makeTimedVideoEndpoint()), raw = try XCTUnwrap(output.endpoints.last)
    let entered = expectation(description: "native enqueue entered")
    let ended = expectation(description: "in-flight enqueue finished")
    let release = DispatchSemaphore(value: 0)
    raw.beforeEnqueue = { entered.fulfill(); _ = release.wait(timeout: .now() + 2) }
    DispatchQueue.global().async {
      _ = endpoint.enqueue(.init(payload: NSObject(), ptsUs: 1, durationUs: 1, keyframe: true, generation: 1))
      ended.fulfill()
    }
    await fulfillment(of: [entered], timeout: 1)
    owner.dispose()
    XCTAssertNil(raw.retirement, "Retire cannot flush while an admitted system enqueue is in flight")
    release.signal()
    await fulfillment(of: [ended], timeout: 1)
    XCTAssertNotNil(raw.retirement)
    raw.beforeEnqueue = nil
    XCTAssertFalse(endpoint.enqueue(.init(payload: NSObject(), ptsUs: 2, durationUs: 1, keyframe: true, generation: 1)))
    raw.retirement?()
  }

  func testTimedWindowDoesNotExceedLeadOrCount() {
    let window = YlTimedVideoWindow()
    window.reset(generation: 1)
    let snapshot = YlPresentationClockSnapshot(positionUs: 1_000_000, hostTimeUs: 10_000_000, rate: 1, playing: true)
    XCTAssertTrue(window.canSubmit(ptsUs: 1_050_000, snapshot: snapshot))
    XCTAssertFalse(window.canSubmit(ptsUs: 1_050_001, snapshot: snapshot))
    for pts: Int64 in [1_010_000, 1_020_000, 1_030_000] {
      window.didSubmit(.init(payload: NSObject(), ptsUs: pts, durationUs: 10_000, keyframe: true, generation: 1))
    }
    XCTAssertFalse(window.canSubmit(ptsUs: 1_040_000, snapshot: snapshot))
    window.advance(to: 1_010_000)
    XCTAssertTrue(window.canSubmit(ptsUs: 1_040_000, snapshot: snapshot))
    XCTAssertFalse(window.canSubmit(ptsUs: 1_030_000, snapshot: snapshot), "Duplicate submitted PTS must remain rejected after capacity frees")
    window.advance(to: 0)
    XCTAssertEqual(window.pendingFrames.map(\.ptsUs), [1_020_000, 1_030_000])
    window.reset(generation: 2)
    XCTAssertTrue(window.pendingFrames.isEmpty)
    window.didSubmit(.init(payload: NSObject(), ptsUs: 1, durationUs: 0, keyframe: true, generation: 1))
    XCTAssertTrue(window.pendingFrames.isEmpty, "An old generation cannot refill the new window")
  }

  func testTimedWindowHandlesPauseRateAndOverflow() {
    let window = YlTimedVideoWindow(); window.reset(generation: 1)
    for (rate, last): (Double, Int64) in [(0.25, 1_012_500), (4, 1_200_000)] {
      let s = YlPresentationClockSnapshot(positionUs: 1_000_000, hostTimeUs: 0, rate: rate, playing: true)
      XCTAssertTrue(window.canSubmit(ptsUs: last, snapshot: s))
      XCTAssertFalse(window.canSubmit(ptsUs: last + 1, snapshot: s))
    }
    XCTAssertFalse(window.canSubmit(ptsUs: 0, snapshot: .init(positionUs: 0, hostTimeUs: 0, rate: 1, playing: false)))
    XCTAssertFalse(window.canSubmit(ptsUs: -1, snapshot: .init(positionUs: 0, hostTimeUs: 0, rate: 1, playing: true)))
    for rate in [Double.nan, .infinity, -1, 0] {
      XCTAssertFalse(window.canSubmit(ptsUs: 0, snapshot: .init(positionUs: 0, hostTimeUs: 0, rate: rate, playing: true)))
    }
    XCTAssertTrue(window.canSubmit(ptsUs: .max, snapshot: .init(positionUs: .max - 1, hostTimeUs: 0, rate: 4, playing: true)))
  }

  func testTimedSchedulerDoesNotCatchUpFutureFrames() {
    let scheduler = YlFrameScheduler(collectDropDiagnostics: true)
    scheduler.flush(generation: 1)
    for pts: Int64 in [30_000, 10_000, 20_000] {
      XCTAssertTrue(scheduler.enqueue(.init(payload: NSObject(), ptsUs: pts, durationUs: 10_000, keyframe: true, generation: 1)))
    }
    XCTAssertNil(scheduler.nextFrame(upTo: 50_000, generation: 2))
    XCTAssertEqual(scheduler.nextFrame(upTo: 50_000, generation: 1)?.ptsUs, 10_000)
    XCTAssertEqual(scheduler.nextFrame(upTo: 50_000, generation: 1)?.ptsUs, 20_000)
    XCTAssertEqual(scheduler.nextFrame(upTo: 50_000, generation: 1)?.ptsUs, 30_000)
    XCTAssertEqual(scheduler.lateFrameDropCount, 0)
    XCTAssertFalse(scheduler.enqueue(.init(payload: NSObject(), ptsUs: 20_000, durationUs: 0, keyframe: true, generation: 1)))
    scheduler.flush(generation: 2)
    XCTAssertTrue(scheduler.enqueue(.init(payload: NSObject(), ptsUs: 1, durationUs: 0, keyframe: true, generation: 2)))
    XCTAssertNil(scheduler.nextFrame(upTo: 0, generation: 2))
    XCTAssertEqual(scheduler.nextFrame(upTo: 1, generation: 2)?.ptsUs, 1)
    scheduler.dispose()
    XCTAssertNil(scheduler.nextFrame(upTo: .max, generation: 2))
  }

  func testTimedClockSnapshotPreservesPauseAndRate() {
    var audio: YlRenderedAudioTime? = .init(sampleTime: 0, sampleRate: 48_000)
    let clock = YlMediaClock(audioTime: { audio })
    clock.play(atHostTimeUs: 1_000_000)
    audio = .init(sampleTime: 24_000, sampleRate: 48_000)
    let playing = clock.presentationSnapshot(atHostTimeUs: 1_500_000)
    XCTAssertEqual(playing.positionUs, 500_000)
    XCTAssertEqual(playing.hostTimeUs, 1_500_000)
    XCTAssertTrue(playing.playing)
    clock.pause(atHostTimeUs: 1_500_000)
    audio = .init(sampleTime: 48_000, sampleRate: 48_000)
    let paused = clock.presentationSnapshot(atHostTimeUs: 2_000_000)
    XCTAssertEqual(paused.positionUs, 500_000); XCTAssertFalse(paused.playing)
    clock.setRate(2, atHostTimeUs: 2_000_000)
    XCTAssertEqual(clock.presentationSnapshot(atHostTimeUs: 2_000_000).rate, 2)
    audio = nil
    clock.play(atHostTimeUs: 2_000_000)
    XCTAssertEqual(clock.presentationSnapshot(atHostTimeUs: 2_250_000).positionUs, 1_000_000)
  }

  private final class DisplayTestWindow: NSWindow {
    var selectedScreen: NSScreen?
    override var screen: NSScreen? { selectedScreen }
  }


  private final class DisplayTestCadence: YlDisplayCadence {
    var isPaused = false
    var invalidated = false
    func invalidate() { invalidated = true }
  }


  func testDisplayTimerFollowsItsOwningWindowAndPreservesPauseWhenScreenChanges() throws {
    let availableScreen = try XCTUnwrap(NSScreen.screens.first)
    let window = DisplayTestWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: .borderless, backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    window.contentView = view
    var requestedScreens: [NSScreen?] = []
    var cadences: [DisplayTestCadence] = []
    let timer = YlDisplayTimer(view: view, cadenceFactory: { screen, _, _ in
      requestedScreens.append(screen)
      let cadence = DisplayTestCadence()
      cadences.append(cadence)
      return cadence
    }) {}
    defer { timer.invalidate() }
    XCTAssertEqual(requestedScreens.count, 1)
    XCTAssertNil(requestedScreens.first!, "An offscreen owning window must not bind another window's display.")
    timer.isPaused = true

    window.selectedScreen = availableScreen
    NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)

    XCTAssertEqual(requestedScreens.count, 2)
    XCTAssertTrue(requestedScreens.last! === availableScreen)
    XCTAssertTrue(cadences.first!.invalidated)
    XCTAssertTrue(cadences.last!.isPaused)
    timer.invalidate()
    NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)
    XCTAssertEqual(requestedScreens.count, 2, "An invalidated timer must not recreate its cadence.")
  }


  func testDisplayTimerFollowsTheActiveScreenRefreshRate() throws {
    guard let screen = NSScreen.main, screen.maximumFramesPerSecond > 30 else {
      throw XCTSkip("An active display faster than 30 Hz is required.")
    }
    let probe = YlDisplayTickProbe()
    let timer = YlDisplayTimer { probe.tick() }
    defer { timer.invalidate() }

    timer.isPaused = false
    let sampleDuration = 0.5
    RunLoop.main.run(until: Date(timeIntervalSinceNow: sampleDuration))

    let minimumTicks = Int(
      Double(screen.maximumFramesPerSecond) * sampleDuration * 0.75
    )
    XCTAssertGreaterThanOrEqual(probe.tickCount, minimumTicks)
  }


  func testMediaClockQueriesExternalAudioTimeWithoutHoldingItsLock() {
    let completed = expectation(description: "media clock play completed")
    var clock: YlMediaClock!
    clock = YlMediaClock(audioTime: {
      clock.anchorAudio(ptsUs: 0, sampleTime: 0)
      return YlRenderedAudioTime(sampleTime: 0, sampleRate: 48_000)
    })

    DispatchQueue.global().async {
      clock.play(atHostTimeUs: 0)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
  }


  func testMediaClockDoesNotReuseStaleAudioAnchorAcrossRateChanges() {
    var rendered: YlRenderedAudioTime? = YlRenderedAudioTime(
      sampleTime: 48_000,
      sampleRate: 48_000
    )
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 5_000_000, sampleTime: 48_000)
    clock.play(atHostTimeUs: 0)

    rendered = YlRenderedAudioTime(sampleTime: 96_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_000_000), 6_000_000)

    rendered = nil
    clock.setRate(2, atHostTimeUs: 1_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 144_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_500_000), 7_000_000)

    rendered = YlRenderedAudioTime(sampleTime: 192_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_000_000), 8_000_000)

    rendered = nil
    clock.setRate(1, atHostTimeUs: 2_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 216_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_500_000), 8_500_000)
  }


  func testMediaClockDoesNotScaleTheTimePitchPlayerTimelineTwice() {
    var rendered = YlRenderedAudioTime(sampleTime: 0, sampleRate: 48_000)
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 0, sampleTime: 0)
    clock.play(atHostTimeUs: 0)

    clock.setRate(3, atHostTimeUs: 0)
    rendered = YlRenderedAudioTime(sampleTime: 144_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_000_000), 3_000_000)

    clock.setRate(1, atHostTimeUs: 1_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 192_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_000_000), 4_000_000)
  }


  func testMediaClockDoesNotReuseStaleAudioAnchorAcrossPauseAndResume() {
    var rendered: YlRenderedAudioTime? = YlRenderedAudioTime(
      sampleTime: 48_000,
      sampleRate: 48_000
    )
    let clock = YlMediaClock(audioTime: { rendered })
    clock.anchorAudio(ptsUs: 5_000_000, sampleTime: 48_000)
    clock.play(atHostTimeUs: 0)

    rendered = YlRenderedAudioTime(sampleTime: 96_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 1_000_000), 6_000_000)

    rendered = nil
    clock.pause(atHostTimeUs: 1_000_000)
    clock.play(atHostTimeUs: 2_000_000)
    rendered = YlRenderedAudioTime(sampleTime: 120_000, sampleRate: 48_000)
    XCTAssertEqual(clock.position(atHostTimeUs: 2_500_000), 6_500_000)
  }


  func testFrameSchedulerPresentsOverdueFramesInOrderAndRejectsOldGeneration() {
    let scheduler = YlFrameScheduler()
    scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 10_000,
      durationUs: 40_000,
      keyframe: false,
      generation: 1
    ))
    scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 20_000,
      durationUs: 40_000,
      keyframe: false,
      generation: 1
    ))

    XCTAssertEqual(scheduler.frame(at: 15_000, generation: 1)?.ptsUs, 10_000)
    XCTAssertEqual(scheduler.frame(at: 25_000, generation: 1)?.ptsUs, 20_000)
    XCTAssertEqual(scheduler.lateFrameDropCount, 0)
    scheduler.flush(generation: 2)
    XCTAssertNil(scheduler.frame(at: 30_000, generation: 1))
  }


  func testFrameSchedulerPresentsTheNewestFrameDueOnEachDisplayTick() {
    let scheduler = YlFrameScheduler()
    for ptsUs in [10_000, 20_000, 30_000] {
      XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(
        payload: NSObject(),
        ptsUs: Int64(ptsUs),
        durationUs: 10_000,
        keyframe: false,
        generation: 1
      )))
    }

    XCTAssertEqual(scheduler.frame(at: 35_000, generation: 1)?.ptsUs, 30_000)
    XCTAssertEqual(scheduler.pendingPTS, [])
    XCTAssertEqual(scheduler.lateFrameDropCount, 2)
  }


  func testFrameSchedulerRejectsAFrameOlderThanTheLastPresentedPTS() {
    let scheduler = YlFrameScheduler()
    XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 20_000,
      durationUs: 10_000,
      keyframe: false,
      generation: 1
    )))
    XCTAssertEqual(scheduler.frame(at: 20_000, generation: 1)?.ptsUs, 20_000)

    XCTAssertFalse(scheduler.enqueue(YlFrameEnvelope(
      payload: NSObject(),
      ptsUs: 10_000,
      durationUs: 10_000,
      keyframe: false,
      generation: 1
    )))
    XCTAssertNil(scheduler.frame(at: 30_000, generation: 1))
    XCTAssertEqual(scheduler.lateFrameDropCount, 1)
  }


  func testFrameSchedulerBackpressuresUntilPresentationFreesCapacity() {
    let scheduler = YlFrameScheduler()
    for ptsUs in [10_000, 20_000, 30_000] {
      XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(
        payload: NSObject(),
        ptsUs: Int64(ptsUs),
        durationUs: 10_000,
        keyframe: false,
        generation: 1
      )))
    }
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      started.signal()
      _ = scheduler.enqueue(YlFrameEnvelope(
        payload: NSObject(),
        ptsUs: 40_000,
        durationUs: 10_000,
        keyframe: false,
        generation: 1
      ))
      completed.signal()
    }

    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    XCTAssertEqual(scheduler.pendingPTS, [10_000, 20_000, 30_000])
    XCTAssertEqual(scheduler.frame(at: 10_000, generation: 1)?.ptsUs, 10_000)
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(scheduler.pendingPTS, [20_000, 30_000, 40_000])
  }

}

private final class YlDisplayTickProbe {
  private let lock = NSLock()
  private var count = 0

  var tickCount: Int {
    lock.withLock { count }
  }

  func tick() {
    lock.withLock { count += 1 }
  }
}
