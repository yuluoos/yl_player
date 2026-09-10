@testable import yl_player_apple
import XCTest
import CoreMedia

final class YlFallbackBufferBudgetTests: XCTestCase {
  func testLowLatencyBudgetUsesSpecifiedCeilings() throws {
    let configuration = PlayerConfiguration(map: ["bufferMode": "lowLatency"])

    let budget = try YlFallbackBufferBudget.make(configuration: configuration)

    XCTAssertEqual(budget.networkBytes, 4 * 1024 * 1024)
    XCTAssertEqual(budget.scheduledAudioBytes, 1 * 1024 * 1024)
    XCTAssertEqual(budget.inFlightPacketBytes, 2 * 1024 * 1024)
  }

  func testBalancedBudgetUsesSpecifiedCeilings() throws {
    let configuration = PlayerConfiguration(map: ["bufferMode": "balanced"])

    let budget = try YlFallbackBufferBudget.make(configuration: configuration)

    XCTAssertEqual(budget.networkBytes, 8 * 1024 * 1024)
    XCTAssertEqual(budget.scheduledAudioBytes, 2 * 1024 * 1024)
    XCTAssertEqual(budget.inFlightPacketBytes, 4 * 1024 * 1024)
  }

  func testAutomaticBudgetMatchesBalanced() throws {
    let automatic = try YlFallbackBufferBudget.make(
      configuration: PlayerConfiguration(map: ["bufferMode": "automatic"])
    )
    let balanced = try YlFallbackBufferBudget.make(
      configuration: PlayerConfiguration(map: ["bufferMode": "balanced"])
    )

    XCTAssertEqual(automatic, balanced)
  }

  func testStableBudgetUsesSpecifiedCeilings() throws {
    let configuration = PlayerConfiguration(map: ["bufferMode": "stable"])

    let budget = try YlFallbackBufferBudget.make(configuration: configuration)

    XCTAssertEqual(budget.networkBytes, 16 * 1024 * 1024)
    XCTAssertEqual(budget.scheduledAudioBytes, 4 * 1024 * 1024)
    XCTAssertEqual(budget.inFlightPacketBytes, 8 * 1024 * 1024)
  }

  func testCustomBudgetSumsExactlyToConfiguredLimit() throws {
    let total = 13 * 1024 * 1024 + 7
    let configuration = PlayerConfiguration(map: [
      "bufferMode": "custom",
      "maxBufferBytes": total,
    ])

    let budget = try YlFallbackBufferBudget.make(configuration: configuration)

    XCTAssertEqual(
      budget.networkBytes + budget.scheduledAudioBytes + budget.inFlightPacketBytes,
      total
    )
    XCTAssertGreaterThanOrEqual(budget.networkBytes, 1024 * 1024)
    XCTAssertGreaterThanOrEqual(budget.scheduledAudioBytes, 1024 * 1024)
    XCTAssertGreaterThanOrEqual(budget.inFlightPacketBytes, 1024 * 1024)
  }

  func testCustomBudgetBelowThreeMiBFails() {
    let configuration = PlayerConfiguration(map: [
      "bufferMode": "custom",
      "maxBufferBytes": 3 * 1024 * 1024 - 1,
    ])

    XCTAssertThrowsError(
      try YlFallbackBufferBudget.make(configuration: configuration)
    ) { error in
      XCTAssertEqual(
        (error as? NativePlayerError)?.code,
        "resource.network_buffer_limit"
      )
    }
  }

  func testParsesAndClampsNetworkConfiguration() {
    let configuration = PlayerConfiguration(map: [
      "decoderPolicy": "hardwareOnly",
      "network": [
        "connectTimeoutMs": -1,
        "readTimeoutMs": 90_000,
        "maxRetries": 99,
        "baseRetryDelayMs": -5,
        "maxRetryDelayMs": 90_000,
        "maxRedirects": 99,
      ],
    ])

    XCTAssertEqual(configuration.decoderPolicy, "hardwareOnly")
    XCTAssertEqual(configuration.network.connectTimeoutMs, 0)
    XCTAssertEqual(configuration.network.readTimeoutMs, 60_000)
    XCTAssertEqual(configuration.network.maxRetries, 20)
    XCTAssertEqual(configuration.network.baseRetryDelayMs, 0)
    XCTAssertEqual(configuration.network.maxRetryDelayMs, 60_000)
    XCTAssertEqual(configuration.network.maxRedirects, 20)
  }
}

final class YlManagedBufferLedgerTests: XCTestCase {
  func testOverflowCategoriesAndDelayedGenerationRelease() throws {
    let ledger = YlManagedBufferLedger(maxBytes: 16 * 1024 * 1024)
    let held = try XCTUnwrap(ledger.reserve(category: .compressedPackets, bytes: 100, generation: 1))
    ledger.invalidate(generation: 1)
    XCTAssertEqual(ledger.snapshot.currentBytes, 100)
    XCTAssertNil(ledger.reserve(category: .networkCache, bytes: 1, generation: 1))
    XCTAssertNil(ledger.reserve(category: .scheduledAudio, bytes: Int.max, generation: 2))
    XCTAssertNil(ledger.reserve(category: .queuedVideoFrames, bytes: -1, generation: 2))
    XCTAssertEqual(ledger.snapshot.categories.values.reduce(0, +), 100)
    held.release(); held.release()
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }
  func testConcurrentReservationsNeverExceedSixteenMiB() {
    let ledger = YlManagedBufferLedger(maxBytes: 16 * 1024 * 1024)
    DispatchQueue.concurrentPerform(iterations: 10000) { i in
      let token = ledger.reserve(category: YlManagedBufferLedger.Category.allCases[i % 4],
        bytes: (i * 997) % (2 * 1024 * 1024), generation: 1)
      let snapshot = ledger.snapshot
      XCTAssertLessThanOrEqual(snapshot.currentBytes, snapshot.maxBytes)
      XCTAssertEqual(snapshot.categories.values.reduce(0, +), snapshot.currentBytes)
      withExtendedLifetime(token) {}
    }
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertLessThanOrEqual(ledger.snapshot.peakBytes, 16 * 1024 * 1024)
  }
  func testAutomaticActiveAndBoundedCandidateShareStricterLimitUntilLastPayloadRelease() throws {
    let ledger = YlManagedBufferLedger()
    let active = try ledger.makeScope(maxBytes: nil)
    let old = try XCTUnwrap(active.reserve(category: .networkCache, bytes: 1024))
    XCTAssertThrowsError(try ledger.makeScope(maxBytes: 512))
    var candidate: YlManagedBufferScope? = try ledger.makeScope(maxBytes: 2048)
    let delayed = try XCTUnwrap(candidate?.reserve(category: .scheduledAudio, bytes: 512))
    XCTAssertNil(active.reserve(category: .compressedPackets, bytes: 1024))
    candidate = nil
    XCTAssertEqual(ledger.snapshot.maxBytes, 2048)
    XCTAssertEqual(ledger.snapshot.currentBytes, 1536)
    delayed.release()
    XCTAssertEqual(ledger.snapshot.maxBytes, Int.max)
    old.release()
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }
  func testRingChargesRewindButNotEmptyCapacityAndReleasesOnActualReset() throws {
    let ledger = YlManagedBufferLedger(maxBytes: 1024)
    let scope = try ledger.makeScope(maxBytes: nil)
    let ring = YlByteRingBuffer(capacity: 512, bufferScope: scope)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertEqual(try ring.append(Data(repeating: 7, count: 256), at: 0), 256)
    var bytes = [UInt8](repeating: 0, count: 128)
    XCTAssertEqual(try bytes.withUnsafeMutableBytes { try ring.read(into: $0) }, 128)
    XCTAssertEqual(ledger.snapshot.currentBytes, 256)
    XCTAssertTrue(ring.seekWithinBuffer(to: 0))
    ring.cancel()
    XCTAssertEqual(ledger.snapshot.currentBytes, 256)
    ring.reset(at: 0)
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }
  func testInspectedFrameMinimumAndDurationOverflowReject() throws {
    XCTAssertThrowsError(try YlBoundedBufferPlan(minDurationMs: 2, maxDurationMs: 1, maxBytes: 16 * 1024 * 1024))
    XCTAssertThrowsError(try YlBoundedBufferPlan(minDurationMs: 0, maxDurationMs: Int64.max, maxBytes: 16 * 1024 * 1024))
    let plan = try YlBoundedBufferPlan(minDurationMs: 200, maxDurationMs: 500, maxBytes: 16 * 1024 * 1024)
    XCTAssertNoThrow(try plan.validate(width: 640, height: 360))
    XCTAssertThrowsError(try plan.validate(width: 8192, height: 8192))
    XCTAssertFalse(plan.admits(durationUs: 490000, nextDurationUs: 20000))
    XCTAssertFalse(plan.ready(durationUs: 100000, eof: false, producerLimited: false))
    XCTAssertTrue(plan.ready(durationUs: 100000, eof: true, producerLimited: false))
    XCTAssertTrue(plan.ready(durationUs: 100000, eof: false, producerLimited: true))
    XCTAssertFalse(plan.ready(durationUs: 0, eof: true, producerLimited: true))
  }
}

extension YlManagedBufferLedgerTests {
  func testNetworkCannotStealAudioAndFrameWorkingSet() throws {
    let ledger = YlManagedBufferLedger()
    let scope = try ledger.makeScope(maxBytes: 16 * 1024 * 1024)
    let available = ledger.availableBytes(category: .networkCache)
    let network = try XCTUnwrap(scope.reserve(category: .networkCache, bytes: available))
    XCTAssertNil(scope.reserve(category: .networkCache, bytes: 1))
    let audio = try XCTUnwrap(scope.reserve(category: .scheduledAudio, bytes: 256 * 1024))
    let frame = try XCTUnwrap(scope.reserve(category: .queuedVideoFrames, bytes: 512 * 1024))
    let packet = try XCTUnwrap(scope.reserve(category: .compressedPackets, bytes: 1024 * 1024))
    XCTAssertEqual(ledger.snapshot.currentBytes, 16 * 1024 * 1024)
    network.release(); audio.release(); frame.release(); packet.release()
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }
  func testPoppedPacketAndHeldFrameRemainChargedAcrossReset() throws {
    let ledger = YlManagedBufferLedger(maxBytes: 1024)
    let scope = try ledger.makeScope(maxBytes: nil)
    let packets = YlBoundedPacketQueue(maxDurationUs: 100000, maxBytes: 1024, bufferScope: scope)
    XCTAssertEqual(packets.push(YlPacketEnvelope(packet: NSObject(), kind: .audio,
      ptsUs: 0, dtsUs: 0, durationUs: 20000, byteCount: 128, keyframe: true, generation: 1)), .accepted)
    var held = packets.pop()
    packets.reset()
    XCTAssertEqual(ledger.snapshot.currentBytes, 128)
    XCTAssertEqual(held?.reservation?.bytes, 128)
    held = nil
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    let frames = YlFrameScheduler()
    var frame: YlFrameEnvelope? = YlFrameEnvelope(reservation: scope.reserve(category: .queuedVideoFrames, bytes: 256),
      payload: NSObject(), ptsUs: 0, durationUs: 40000, keyframe: true, generation: 1)
    XCTAssertTrue(frames.enqueue(frame!))
    frames.flush(generation: 2)
    XCTAssertEqual(ledger.snapshot.currentBytes, 256)
    frame = nil
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }
  func testQueueTimestampsEnforceMaximumAndSeekClearsDuration() throws {
    let plan = try YlBoundedBufferPlan(minDurationMs: 80, maxDurationMs: 120, maxBytes: 16 * 1024 * 1024)
    let scheduler = YlFrameScheduler()
    scheduler.configureBounded(plan)
    for index in 0..<3 {
      XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(payload: NSObject(), ptsUs: Int64(index) * 40000,
        durationUs: 40000, keyframe: true, generation: 1)))
    }
    XCTAssertEqual(scheduler.bufferedDurationUs, 120000)
    XCTAssertTrue(plan.ready(durationUs: scheduler.bufferedDurationUs, eof: false, producerLimited: false))
    XCTAssertFalse(scheduler.enqueue(YlFrameEnvelope(payload: NSObject(), ptsUs: 120000,
      durationUs: 40000, keyframe: true, generation: 1)))
    let clock = YlMediaClock(); clock.play(atHostTimeUs: 0); clock.setRate(2, atHostTimeUs: 0)
    XCTAssertNotNil(scheduler.frame(at: clock.position(atHostTimeUs: 40000), generation: 1))
    XCTAssertEqual(scheduler.bufferedDurationUs, 0)
    scheduler.flush(generation: 2)
    XCTAssertTrue(scheduler.enqueue(YlFrameEnvelope(payload: NSObject(), ptsUs: 900000,
      durationUs: 40000, keyframe: true, generation: 2)))
    XCTAssertFalse(plan.ready(durationUs: scheduler.bufferedDurationUs, eof: false, producerLimited: false))
    XCTAssertTrue(plan.ready(durationUs: scheduler.bufferedDurationUs, eof: true, producerLimited: false))
  }
}


extension YlManagedBufferLedgerTests {
  func testRetainedPacketTimingTransfersAndOldEpochKeepsBytesWithoutBlockingSeek() throws {
    let ledger = YlManagedBufferLedger()
    let scope = try ledger.makeScope(maxBytes: 16 * 1024 * 1024)
    scope.configureTimeline(try YlBoundedBufferPlan(minDurationMs: 80, maxDurationMs: 120, maxBytes: 16 * 1024 * 1024))
    let packet = try scope.require(category: .compressedPackets, bytes: 100)
    XCTAssertTrue(packet.carryTiming(ptsUs: 0, durationUs: 40000))
    let frame = try scope.require(category: .queuedVideoFrames, bytes: 200)
    XCTAssertTrue(frame.carryTiming(ptsUs: 0, durationUs: 0, from: packet))
    packet.endQueuedTiming()
    XCTAssertEqual(scope.bufferedDurationUs, 40000)
    XCTAssertEqual(ledger.snapshot.currentBytes, 300)
    scope.beginMediaGeneration()
    XCTAssertEqual(scope.bufferedDurationUs, 0)
    XCTAssertEqual(ledger.snapshot.currentBytes, 300)
    let delayed = try scope.require(category: .queuedVideoFrames, bytes: 200)
    XCTAssertTrue(delayed.carryTiming(ptsUs: 0, durationUs: 40000, from: packet))
    XCTAssertEqual(scope.bufferedDurationUs, 0)
    let fresh = try scope.require(category: .compressedPackets, bytes: 100)
    XCTAssertTrue(fresh.carryTiming(ptsUs: 900000, durationUs: 20000))
    XCTAssertEqual(scope.bufferedDurationUs, 20000)
    packet.release(); frame.release(); delayed.release(); fresh.release()
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
    XCTAssertEqual(scope.bufferedDurationUs, 0)
  }
  func testStrictPacketDurationRejectsUnknownOversizeAndReorderingBeyondMaximum() throws {
    let ledger = YlManagedBufferLedger()
    let scope = try ledger.makeScope(maxBytes: 16 * 1024 * 1024)
    scope.configureTimeline(try YlBoundedBufferPlan(minDurationMs: 80, maxDurationMs: 120, maxBytes: 16 * 1024 * 1024))
    let first = try scope.require(category: .compressedPackets, bytes: 100)
    XCTAssertTrue(first.carryTiming(ptsUs: 40000, durationUs: 40000))
    scope.observePacketDuration(40000)
    let reordered = try scope.require(category: .compressedPackets, bytes: 100)
    XCTAssertTrue(reordered.carryTiming(ptsUs: 0, durationUs: 40000))
    XCTAssertEqual(scope.bufferedDurationUs, 80000)
    XCTAssertTrue(scope.shouldPausePacketAdmission)
    let next = try scope.require(category: .compressedPackets, bytes: 100)
    XCTAssertFalse(next.carryTiming(ptsUs: Int64.min, durationUs: 40000))
    XCTAssertFalse(next.carryTiming(ptsUs: 80000, durationUs: 0))
    XCTAssertFalse(next.carryTiming(ptsUs: 80000, durationUs: 120001))
    XCTAssertFalse(next.carryTiming(ptsUs: Int64.max, durationUs: 40000))
    XCTAssertFalse(next.carryTiming(ptsUs: 100000, durationUs: 40000))
    XCTAssertEqual(scope.bufferedDurationUs, 80000)
    XCTAssertTrue(next.carryTiming(ptsUs: 80000, durationUs: 40000))
    XCTAssertEqual(scope.bufferedDurationUs, 120000)
  }
}


extension YlManagedBufferLedgerTests {
  func testFLVAACConfigurationRequiresCompleteInactiveSyncExtension() {
    let fixture = Data([0x11, 0x88, 0x56, 0xe5, 0x00])
    let parsed = ylInspectedAACLCConfiguration(cookie: fixture)
    XCTAssertEqual(parsed?.sampleRate, 48000); XCTAssertEqual(parsed?.channelCount, 1)
    XCTAssertEqual(parsed?.framesPerPacket, 1024)
    XCTAssertEqual(ylBoundedAACPacketDurationUs(sampleRate: 48000, cookie: fixture), 21334)
    XCTAssertNil(ylBoundedAACPacketDurationUs(sampleRate: 44100, cookie: fixture))
    for bytes: [UInt8] in [[0x11, 0x88, 0x56, 0xe5], [0x11, 0x88, 0x56, 0xe5, 0x80],
                          [0x11, 0x88, 0x56, 0xe4, 0], [0x11, 0x88, 0x56, 0xe5, 1],
                          [0x11, 0x88, 0], [0x11, 0x80], [0x29, 0x88], [0x17, 0x88]] {
      XCTAssertNil(ylInspectedAACLCConfiguration(cookie: Data(bytes)))
    }
  }
  func testMissingAACPacketDurationUsesInspectedLCFrameLengthWithoutGuessing() {
    XCTAssertEqual(ylBoundedAACPacketDurationUs(sampleRate: 48000, cookie: Data([0x11, 0x90])), 21334)
    XCTAssertEqual(ylBoundedAACPacketDurationUs(sampleRate: 48000, cookie: Data([0x11, 0x94])), 20000)
    XCTAssertNil(ylBoundedAACPacketDurationUs(sampleRate: 44100, cookie: Data([0x11, 0x90])))
    XCTAssertNil(ylBoundedAACPacketDurationUs(sampleRate: 48000, cookie: Data([0x29, 0x90])))
    XCTAssertNil(ylBoundedAACPacketDurationUs(sampleRate: 48000, cookie: Data([0x11])))
    XCTAssertNil(ylBoundedAACPacketDurationUs(sampleRate: 48000, cookie: Data([0xf8, 0x90])))
    XCTAssertNil(ylBoundedAACPacketDurationUs(sampleRate: 48000, cookie: Data([0x11, 0x92])))
  }
}


extension YlManagedBufferLedgerTests {
  func testConsumedHighFrameForecastBackpressuresUntilOlderAudioReleases() throws {
    let scope = try YlManagedBufferLedger().makeScope(maxBytes: 16 * 1024 * 1024)
    scope.configureTimeline(try YlBoundedBufferPlan(minDurationMs: 100, maxDurationMs: 500, maxBytes: 16 * 1024 * 1024))
    let audio = try scope.require(category: .scheduledAudio, bytes: 100)
    XCTAssertTrue(audio.carryTiming(ptsUs: 491000, durationUs: 21334))
    scope.observePacketDuration(41000, ptsUs: 625000)
    scope.observePacketDuration(41000, ptsUs: 792000)
    XCTAssertEqual(scope.bufferedDurationUs, 21334)
    XCTAssertTrue(scope.shouldPausePacketAdmission)
    audio.endQueuedTiming()
    XCTAssertFalse(scope.shouldPausePacketAdmission)
    XCTAssertTrue(audio.carryTiming(ptsUs: 512000, durationUs: 21334))
    XCTAssertFalse(scope.shouldPausePacketAdmission)
    let next = try scope.require(category: .compressedPackets, bytes: 100)
    XCTAssertTrue(next.carryTiming(ptsUs: 958000, durationUs: 41000))
    XCTAssertEqual(scope.bufferedDurationUs, 487000)
  }
  func testCopiedSampleAndHeldBackingKeepOneReceiptAfterOriginalRelease() throws {
    let ledger = YlManagedBufferLedger(maxBytes: 1024)
    let scope = try ledger.makeScope(maxBytes: nil)
    var token: YlManagedBufferLedger.Token? = try scope.require(category: .compressedPackets, bytes: 128)
    var block: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
      memoryBlock: nil, blockLength: 128, blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil, offsetToData: 0, dataLength: 128, flags: 0,
      blockBufferOut: &block), noErr)
    var sample: CMSampleBuffer?
    var size = 128
    XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
      dataBuffer: block, formatDescription: nil, sampleCount: 1,
      sampleTimingEntryCount: 0, sampleTimingArray: nil,
      sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample), noErr)
    ylRetainManagedPayload(token!, in: try XCTUnwrap(sample))
    var copy: CMSampleBuffer?
    XCTAssertEqual(CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: sample!, sampleBufferOut: &copy), noErr)
    token = nil; sample = nil; block = nil
    scope.beginMediaGeneration()
    XCTAssertEqual(ledger.snapshot.currentBytes, 128)
    block = CMSampleBufferGetDataBuffer(try XCTUnwrap(copy))
    copy = nil
    XCTAssertEqual(ledger.snapshot.currentBytes, 128)
    block = nil
    XCTAssertEqual(ledger.snapshot.currentBytes, 0)
  }
}
