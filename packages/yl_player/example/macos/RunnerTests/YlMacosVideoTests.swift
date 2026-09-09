@testable import yl_player_apple
import AppKit
import AVFAudio
import Foundation
import VideoToolbox
import XCTest
import YlFFmpegBridge

final class YlMacosVideoTests: XCTestCase {
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
    let decoder: YlVideoToolboxDecoder
    do {
      decoder = try YlVideoToolboxDecoder(
        formatDescription: format,
        onFrame: { frame in
          outputLock.withLock {
            outputPixelFormat = CVPixelBufferGetPixelFormatType(frame.pixelBuffer)
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
    let constraint = try YlFallbackQualityConstraint(validating: [
      "maxWidth": 1_920,
      "maxHeight": 1_080,
      "maxBitrate": 8_000_000,
    ])

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
