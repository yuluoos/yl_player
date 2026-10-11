@testable import yl_player_apple
import AppKit
import AVFAudio
import Foundation
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosVideoTests: XCTestCase {
  private func diagnosticFrame(_ pts: Int64, generation: UInt64 = 1, payload: AnyObject = NSObject()) -> YlFrameEnvelope {
    .init(payload: payload, ptsUs: pts, durationUs: 40_000, keyframe: false, generation: generation)
  }

  func testDropDiagnosticsDescribeCatchUpWithoutRetainingFrames() throws {
    let scheduler = YlFrameScheduler(collectDropDiagnostics: true)
    scheduler.enqueue(diagnosticFrame(0))
    XCTAssertEqual(scheduler.frame(at: 0, generation: 1)?.ptsUs, 0)
    weak var payload: NSObject?
    do {
      let object = NSObject(); payload = object
      scheduler.enqueue(diagnosticFrame(40_000, payload: object))
    }
    scheduler.enqueue(diagnosticFrame(80_000)); scheduler.enqueue(diagnosticFrame(120_000))
    XCTAssertEqual(scheduler.frame(at: 125_000, generation: 1)?.ptsUs, 120_000)
    XCTAssertNil(payload)
    XCTAssertEqual(scheduler.lateFrameDropCount, 2)
    let snapshot = scheduler.dropDiagnostics
    XCTAssertEqual(snapshot.total, 2)
    XCTAssertEqual(snapshot.counts[.catchUp], 2)
    let event = try XCTUnwrap(snapshot.events.first)
    XCTAssertEqual(event.reason, .catchUp); XCTAssertEqual(event.count, 2); XCTAssertEqual(event.total, 2)
    XCTAssertEqual(event.firstPTS, 40_000); XCTAssertEqual(event.lastPTS, 80_000)
    XCTAssertEqual(event.queueCount, 3); XCTAssertEqual(event.generation, 1)
    XCTAssertEqual(event.positionUs, 125_000); XCTAssertEqual(event.selectedPTS, 120_000)
    XCTAssertEqual(event.previousPositionUs, 0)
    XCTAssertLessThanOrEqual(try XCTUnwrap(event.previousTickUptime), event.uptime)
  }

  func testDropDiagnosticsClassifyRejectionsAndStayBoundedAcrossFlush() throws {
    let scheduler = YlFrameScheduler(maxFrames: 1, enqueueWaitTimeout: 0, collectDropDiagnostics: true)
    scheduler.enqueue(diagnosticFrame(0))
    XCTAssertFalse(scheduler.enqueue(diagnosticFrame(40_000)))
    XCTAssertEqual(scheduler.frame(at: 0, generation: 1)?.ptsUs, 0)
    for _ in 0..<20 { XCTAssertFalse(scheduler.enqueue(diagnosticFrame(0))) }
    scheduler.configureBounded(try .init(minDurationMs: 0, maxDurationMs: 20, maxBytes: 4_000_000))
    XCTAssertFalse(scheduler.enqueue(diagnosticFrame(80_000)))
    let snapshot = scheduler.dropDiagnostics
    XCTAssertEqual(snapshot.counts[.enqueueTimeout], 1)
    XCTAssertEqual(snapshot.counts[.lateArrival], 20)
    XCTAssertEqual(snapshot.counts[.durationLimit], 1)
    XCTAssertEqual(snapshot.counts.values.reduce(0, +), scheduler.lateFrameDropCount)
    XCTAssertEqual(snapshot.events.count, 16)
    XCTAssertEqual(snapshot.events.first?.total, 7); XCTAssertEqual(snapshot.events.last?.total, 22)
    XCTAssertEqual(snapshot.events.last?.reason, .durationLimit)
    scheduler.flush(generation: 2); scheduler.configureBounded(nil)
    scheduler.enqueue(diagnosticFrame(0, generation: 2))
    XCTAssertFalse(scheduler.enqueue(diagnosticFrame(40_000, generation: 2)))
    let event = try XCTUnwrap(scheduler.dropDiagnostics.events.last)
    XCTAssertEqual(event.generation, 2); XCTAssertNil(event.previousPositionUs); XCTAssertNil(event.previousTickUptime)
    XCTAssertGreaterThanOrEqual(event.enqueueWaitSeconds, 0)
    scheduler.dispose()
    XCTAssertEqual(scheduler.dropDiagnostics.events.last?.total, 23)
  }

  func testDropDiagnosticsDisabledPreservesDropBehaviorWithoutEvents() {
    let scheduler = YlFrameScheduler()
    scheduler.enqueue(diagnosticFrame(0)); scheduler.enqueue(diagnosticFrame(40_000))
    XCTAssertEqual(scheduler.frame(at: 40_000, generation: 1)?.ptsUs, 40_000)
    XCTAssertEqual(scheduler.lateFrameDropCount, 1)
    XCTAssertEqual(scheduler.dropDiagnostics.total, 1)
    XCTAssertTrue(scheduler.dropDiagnostics.events.isEmpty)
    XCTAssertTrue(scheduler.dropDiagnostics.counts.isEmpty)
  }

  func testDropDiagnosticsSeparateCatchUpFromProducerOvertakenDuringWait() throws {
    let scheduler = YlFrameScheduler(maxFrames: 1, enqueueWaitTimeout: 2, collectDropDiagnostics: true)
    scheduler.enqueue(diagnosticFrame(40_000))
    let completed = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      XCTAssertFalse(scheduler.enqueue(self.diagnosticFrame(20_000)))
      completed.signal()
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 1
    while scheduler.dropDiagnostics.waitingEnqueues == 0 && ProcessInfo.processInfo.systemUptime < deadline {
      Thread.sleep(forTimeInterval: 0.001)
    }
    XCTAssertEqual(scheduler.dropDiagnostics.waitingEnqueues, 1)
    XCTAssertEqual(scheduler.frame(at: 40_000, generation: 1)?.ptsUs, 40_000)
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(scheduler.dropDiagnostics.waitingEnqueues, 0)
    XCTAssertEqual(scheduler.dropDiagnostics.counts[.lateAfterCapacity], 1)
    XCTAssertEqual(scheduler.lateFrameDropCount, 1)
    let event = try XCTUnwrap(scheduler.dropDiagnostics.events.last)
    XCTAssertEqual(event.firstPTS, 20_000)
    XCTAssertGreaterThan(event.enqueueWaitSeconds, 0)
  }

  func testPendingVideoReservationCountIsBoundedEvenForEmptyPackets() throws {
    let budget = YlVideoDecodeBudget(maxBytes: 100, maxFrames: 1, maxPendingFrames: 2)
    let first = try XCTUnwrap(budget.reservePending(byteCount: 0, timeout: 0))
    let second = try XCTUnwrap(budget.reservePending(byteCount: 0, timeout: 0))
    XCTAssertThrowsError(try budget.reservePending(byteCount: 0, timeout: 0))
    first.release()
    XCTAssertNotNil(try budget.reservePending(byteCount: 0, timeout: 0))
    second.release()
  }


  func testPendingVideoReservationsShareTheDecodeByteBudget() throws {
    let budget = YlVideoDecodeBudget(maxBytes: 12, maxFrames: 1)
    let first = try XCTUnwrap(budget.reservePending(byteCount: 8, timeout: 0))
    let second = try XCTUnwrap(budget.reservePending(byteCount: 4, timeout: 0))
    XCTAssertEqual(budget.inFlightBytes, 12)
    XCTAssertThrowsError(try budget.reservePending(byteCount: 1, timeout: 0))
    XCTAssertTrue(try first.beginDecoding(shouldCancel: { false }))
    XCTAssertEqual(budget.inFlightFrames, 1)
    XCTAssertFalse(try second.beginDecoding(shouldCancel: { true }))
    first.release()
    XCTAssertTrue(try second.beginDecoding(shouldCancel: { false }))
    second.release()
    XCTAssertEqual(budget.inFlightBytes, 0)
    XCTAssertEqual(budget.inFlightFrames, 0)
  }


  func testCancellingVideoSubmissionsReleasesQueuedSamplesBeforeJoining() throws {
    let queue = YlVideoSubmissionQueue()
    let entered = DispatchSemaphore(value: 0)
    let releaseActive = DispatchSemaphore(value: 0)
    queue.submit {
      entered.signal()
      _ = releaseActive.wait(timeout: .now() + 2)
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    let budget = YlVideoDecodeBudget(maxBytes: 12)
    weak var retainedSample: NSObject?
    do {
      let sample = NSObject()
      let reservation = try XCTUnwrap(budget.reservePending(byteCount: 12, timeout: 0))
      retainedSample = sample
      queue.submit { withExtendedLifetime((sample, reservation)) {} }
    }
    XCTAssertNotNil(retainedSample)
    queue.cancelPending()
    XCTAssertNil(retainedSample, "Cancellation must release pending payloads even while a decode is running.")
    XCTAssertEqual(budget.inFlightBytes, 0)
    XCTAssertFalse(queue.isDrained)
    releaseActive.signal()
    queue.waitUntilIdle()
    XCTAssertTrue(queue.isDrained)
  }


  func testVideoQueuePreservesSubmissionOrderAndAcceptsWorkAfterCancellation() {
    let queue = YlVideoSubmissionQueue()
    var order: [Int] = []
    queue.submit { order.append(1) }
    queue.submit { order.append(2) }
    queue.waitUntilIdle()
    queue.cancelPending()
    queue.submit { order.append(3) }
    queue.waitUntilIdle()
    XCTAssertEqual(order, [1, 2, 3])
  }


  func testVideoDecodeBudgetReservationsBoundBytesAndFrameCount() throws {
    let budget = YlVideoDecodeBudget(maxBytes: 100, maxFrames: 2)

    var first = try XCTUnwrap(budget.reserve(byteCount: 60, timeout: 0))
    XCTAssertThrowsError(try budget.reserve(byteCount: 50, timeout: 0)) {
      XCTAssertEqual(
        ($0 as? NativePlayerError)?.code,
        "resource.video_decoder_backpressure_timeout"
      )
    }
    let second = try XCTUnwrap(budget.reserve(byteCount: 40, timeout: 0))
    XCTAssertThrowsError(try budget.reserve(byteCount: 1, timeout: 0))

    first.release()
    first = try XCTUnwrap(budget.reserve(byteCount: 50, timeout: 0))
    budget.reset()
    XCTAssertEqual(budget.inFlightBytes, 0)
    XCTAssertEqual(budget.inFlightFrames, 0)
    let replacement = try XCTUnwrap(budget.reserve(byteCount: 100, timeout: 0))
    first.release()
    second.release()
    XCTAssertEqual(budget.inFlightBytes, 100)
    XCTAssertEqual(budget.inFlightFrames, 1)
    replacement.release()
  }


  func testVideoToolboxRequestsDisplayOrderForAsynchronousFrames() {
    XCTAssertTrue(
      YlVideoToolboxDecodePolicy.frameFlags.contains(._EnableTemporalProcessing)
    )
  }


  func testVideoToolboxDoesNotRestrictDecodeThroughputToOneTimesRealtime() {
    XCTAssertFalse(
      YlVideoToolboxDecodePolicy.frameFlags.contains(._1xRealTimePlayback)
    )
  }


  func testVideoToolboxOutputsFlutterNativeBiPlanarPixelBuffers() throws {
    let exampleRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let fixture = exampleRoot.appendingPathComponent(
      "assets/test_media/h264_aac.mkv"
    )
    var context: YLFMediaContextRef?
    var mediaInfo = YLFMediaInfo()
    let openResult = fixture.withUnsafeFileSystemRepresentation { path in
      ylf_open_local(path, &context, &mediaInfo)
    }
    XCTAssertEqual(openResult, Int32(YLFResultOK))
    guard let context else {
      XCTFail("The Matroska fixture did not open.")
      return
    }
    var ownedContext: YLFMediaContextRef? = context
    defer { ylf_close(&ownedContext) }

    var videoStreamIndex: Int32?
    for index in 0..<mediaInfo.stream_count {
      var stream = YLFStreamInfo()
      if ylf_copy_stream_info(context, index, &stream) == 0,
         Int(stream.kind) == YLFStreamVideo {
        videoStreamIndex = stream.index
        break
      }
    }
    let streamIndex = try XCTUnwrap(videoStreamIndex)
    let format = try YlVideoToolboxDecoder.makeFormatDescription(
      context: context,
      streamIndex: streamIndex
    )
    let frameExpectation = expectation(
      description: "VideoToolbox outputs a Flutter-compatible YUV frame"
    )
    frameExpectation.assertForOverFulfill = false
    let outputLock = NSLock()
    var outputPixelFormat: OSType?
    var outputSurfaceDiagnostics: [String: Any]?
    let decoder: YlVideoToolboxDecoder
    do {
      decoder = try YlVideoToolboxDecoder(
        formatDescription: format,
        onFrame: { frame in
          outputLock.withLock {
            outputPixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
            let buffer = frame.pixelBuffer
            outputSurfaceDiagnostics = [
              "coreAnimationCompatible": CVPixelBufferIsCompatibleWithAttributes(
                buffer,
                [kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey: true] as CFDictionary
              ),
              "pixelFormat": CVPixelBufferGetPixelFormatType(buffer),
              "width": CVPixelBufferGetWidth(buffer),
              "height": CVPixelBufferGetHeight(buffer),
              "dataSize": CVPixelBufferGetDataSize(buffer),
              "planeStrides": (0..<CVPixelBufferGetPlaneCount(buffer)).map {
                CVPixelBufferGetBytesPerRowOfPlane(buffer, $0)
              },
            ]
          }
          frameExpectation.fulfill()
        },
        onError: { error in
          XCTFail("Unexpected decoder error: \(error)")
        }
      )
    } catch let error as NativePlayerError
      where error.code == "decoder.video_hardware_unavailable" {
      throw XCTSkip("VideoToolbox hardware decoding is unavailable on this host.")
    }
    defer { decoder.dispose() }

    for _ in 0..<120 {
      var packet: YLFPacketRef?
      let readResult = ylf_read_packet(context, &packet)
      if readResult == Int32(YLFResultEOF) { break }
      XCTAssertEqual(readResult, Int32(YLFResultOK))
      guard let ownedPacket = packet else { continue }
      guard ylf_packet_stream_index(ownedPacket) == streamIndex else {
        ylf_packet_release(&packet)
        continue
      }
      let reservation = try XCTUnwrap(decoder.reserve(
        byteCount: ylf_packet_size(ownedPacket),
        shouldCancel: { false }
      ))
      var unmanagedSample: Unmanaged<CMSampleBuffer>?
      let sampleResult = ylf_create_video_sample_buffer(
        &packet,
        format,
        &unmanagedSample
      )
      guard sampleResult == Int32(YLFResultOK), let unmanagedSample else {
        reservation.release()
        ylf_packet_release(&packet)
        XCTFail("The fixture packet could not become a video sample.")
        break
      }
      decoder.decode(
        sample: unmanagedSample.takeRetainedValue(),
        generation: 1,
        reservation: reservation
      )
    }
    decoder.drain()
    wait(for: [frameExpectation], timeout: 2)
    // Copy only scalar evidence: diagnostics must not retain a decoded buffer
    // or serialize the creation dictionary's native callback/address values.
    let surfaceDiagnostics = try XCTUnwrap(outputLock.withLock { outputSurfaceDiagnostics })
    let attachment = XCTAttachment(data: try JSONSerialization.data(
      withJSONObject: surfaceDiagnostics, options: [.sortedKeys]
    ), uniformTypeIdentifier: "public.json")
    attachment.name = "decoded-pixel-surface-compatibility"
    attachment.lifetime = .keepAlways
    add(attachment)

    XCTAssertEqual(
      outputLock.withLock { outputPixelFormat },
      kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    )
  }


  func testVideoDecodeBudgetWaiterUnblocksWhenReservationReleases() throws {
    let budget = YlVideoDecodeBudget(maxBytes: 100, maxFrames: 1)
    let first = try XCTUnwrap(budget.reserve(byteCount: 100, timeout: 0))
    let started = DispatchSemaphore(value: 0)
    let completed = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var didReserve = false

    DispatchQueue.global().async {
      started.signal()
      let second = try? budget.reserve(byteCount: 1, timeout: 1)
      resultLock.withLock { didReserve = second != nil }
      second?.release()
      completed.signal()
    }

    XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(completed.wait(timeout: .now() + 0.05), .timedOut)
    first.release()
    XCTAssertEqual(completed.wait(timeout: .now() + 1), .success)
    XCTAssertTrue(resultLock.withLock { didReserve })
    XCTAssertNil(try budget.reserve(
      byteCount: 1,
      timeout: 1,
      shouldCancel: { true }
    ))
  }


  func testHardwareDecoderLeaseEnforcesAdvertisedConcurrency() throws {
    let pool = YlHardwareDecoderLeasePool(maxConcurrentLeases: 1)
    var first: YlHardwareDecoderLease? = try pool.acquire()
    XCTAssertNotNil(first)

    XCTAssertThrowsError(try pool.acquire()) {
      XCTAssertEqual(
        ($0 as? NativePlayerError)?.code,
        "resource.video_decoder_limit"
      )
    }
    first = nil
    XCTAssertNoThrow(try pool.acquire())
  }


  func testQualityConstraintRejectsOversizedFixedVideo() throws {
    let constraint = try YlFallbackQualityConstraint(validating: YlAppleVideoConstraints(maxWidth: 1_920, maxHeight: 1_080, maxBitrate: 8_000_000))

    XCTAssertThrowsError(try YlFallbackQualityPolicy.validate(
      constraint: constraint,
      stream: YlFallbackVideoDescriptor(
        width: 3_840,
        height: 2_160,
        bitrate: 12_000_000
      )
    )) {
      XCTAssertEqual(
        ($0 as? NativePlayerError)?.code,
        "decoder.quality_constraint_unsupported"
      )
    }
  }

}
