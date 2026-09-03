import XCTest
import YlFFmpegBridge
import CoreMedia
import Darwin

private final class CallbackFixture {
    let bytes: Data
    var offset = 0
    var cancelCount = 0
    var failReads = false

    init(bytes: Data) {
        self.bytes = bytes
    }

    var opaque: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

private func callbackFixture(
    _ opaque: UnsafeMutableRawPointer?
) -> CallbackFixture? {
    guard let opaque else { return nil }
    return Unmanaged<CallbackFixture>.fromOpaque(opaque).takeUnretainedValue()
}

private func fixtureRead(
    _ opaque: UnsafeMutableRawPointer?,
    _ buffer: UnsafeMutablePointer<UInt8>?,
    _ capacity: Int32
) -> Int32 {
    guard let fixture = callbackFixture(opaque),
          let buffer,
          capacity > 0 else { return -1 }
    if fixture.failReads { return -1 }
    guard fixture.offset < fixture.bytes.count else { return 0 }
    let count = min(Int(capacity), fixture.bytes.count - fixture.offset)
    fixture.bytes.copyBytes(
        to: buffer,
        from: fixture.offset..<(fixture.offset + count)
    )
    fixture.offset += count
    return Int32(count)
}

private func fixtureSeek(
    _ opaque: UnsafeMutableRawPointer?,
    _ offset: Int64,
    _ whence: Int32
) -> Int64 {
    guard let fixture = callbackFixture(opaque) else { return -1 }
    let avSeekSize: Int32 = 0x10000
    let avSeekForce: Int32 = 0x20000
    if whence == avSeekSize { return Int64(fixture.bytes.count) }
    let origin = whence & ~avSeekForce
    let base: Int64
    switch origin {
    case SEEK_SET:
        base = 0
    case SEEK_CUR:
        base = Int64(fixture.offset)
    case SEEK_END:
        base = Int64(fixture.bytes.count)
    default:
        return -1
    }
    let target = base.addingReportingOverflow(offset)
    guard !target.overflow,
          target.partialValue >= 0,
          target.partialValue <= Int64(fixture.bytes.count) else { return -1 }
    fixture.offset = Int(target.partialValue)
    return target.partialValue
}

private func fixtureCancel(_ opaque: UnsafeMutableRawPointer?) {
    callbackFixture(opaque)?.cancelCount += 1
}

final class YlFFmpegBridgeTests: XCTestCase {
    private let unknownTimestamp = Int64.min

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "mkv"),
            "Missing bundled fixture \(name).mkv"
        )
    }

    private func open(_ name: String) throws -> (YLFMediaContextRef?, YLFMediaInfo) {
        var context: YLFMediaContextRef?
        var info = YLFMediaInfo()
        let path = try fixture(name).path
        let result = path.withCString { ylf_open_local($0, &context, &info) }
        XCTAssertEqual(result, 0)
        XCTAssertNotNil(context)
        return (context, info)
    }

    func testReadsH264AACMetadataPacketsEOFAndSeek() throws {
        var (context, mediaInfo) = try open("h264_aac")
        defer { ylf_close(&context) }

        XCTAssertEqual(mediaInfo.stream_count, 2)
        XCTAssertGreaterThan(mediaInfo.duration_us, 1_900_000)

        var streams = [YLFStreamInfo]()
        for index in 0..<mediaInfo.stream_count {
            var stream = YLFStreamInfo()
            XCTAssertEqual(ylf_copy_stream_info(context, index, &stream), 0)
            streams.append(stream)
        }

        let video = try XCTUnwrap(streams.first { $0.kind == 1 })
        XCTAssertEqual(video.codec, 1)
        XCTAssertEqual(video.width, 320)
        XCTAssertEqual(video.height, 180)

        let audio = try XCTUnwrap(streams.first { $0.kind == 2 })
        XCTAssertEqual(audio.codec, 3)
        XCTAssertEqual(audio.sample_rate, 48_000)
        XCTAssertEqual(audio.channel_count, 1)

        var minimumTimestamp = Int64.max
        var maximumTimestamp = Int64.min
        var sawVideoKeyframe = false
        var packetCount = 0
        while true {
            var packet: YLFPacketRef?
            let result = ylf_read_packet(context, &packet)
            if result == 1 {
                XCTAssertNil(packet)
                break
            }
            XCTAssertEqual(result, 0)
            let ownedPacket = try XCTUnwrap(packet)
            let streamIndex = ylf_packet_stream_index(ownedPacket)
            XCTAssertTrue(streamIndex == video.index || streamIndex == audio.index)
            XCTAssertGreaterThan(ylf_packet_size(ownedPacket), 0)

            let timestamp = ylf_packet_pts_us(ownedPacket)
            if timestamp != unknownTimestamp {
                minimumTimestamp = min(minimumTimestamp, timestamp)
                maximumTimestamp = max(maximumTimestamp, timestamp)
            }
            if streamIndex == video.index && ylf_packet_is_keyframe(ownedPacket) {
                sawVideoKeyframe = true
            }
            packetCount += 1
            ylf_packet_release(&packet)
            XCTAssertNil(packet)
        }

        XCTAssertGreaterThan(packetCount, 50)
        XCTAssertTrue(sawVideoKeyframe)
        XCTAssertGreaterThan(maximumTimestamp - minimumTimestamp, 1_800_000)
        XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)

        XCTAssertEqual(ylf_seek(context, 0), 0)
        var packetAfterSeek: YLFPacketRef?
        XCTAssertEqual(ylf_read_packet(context, &packetAfterSeek), 0)
        XCTAssertNotNil(packetAfterSeek)
        ylf_packet_release(&packetAfterSeek)
        XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
    }

    func testReportsBothAudioTracks() throws {
        var (context, mediaInfo) = try open("two_audio_tracks")
        defer { ylf_close(&context) }

        var audioCount = 0
        for index in 0..<mediaInfo.stream_count {
            var stream = YLFStreamInfo()
            XCTAssertEqual(ylf_copy_stream_info(context, index, &stream), 0)
            if stream.kind == 2 && stream.codec == 3 {
                audioCount += 1
            }
        }
        XCTAssertEqual(audioCount, 2)
    }

    func testCopiesAACCodecConfiguration() throws {
        var (context, mediaInfo) = try open("h264_aac")
        defer { ylf_close(&context) }
        var audioIndex: Int32?
        for index in 0..<mediaInfo.stream_count {
            var stream = YLFStreamInfo()
            XCTAssertEqual(ylf_copy_stream_info(context, index, &stream), 0)
            if Int(stream.kind) == YLFStreamAudio { audioIndex = stream.index }
        }
        let streamIndex = try XCTUnwrap(audioIndex)
        let size = ylf_stream_codec_config_size(context, streamIndex)
        XCTAssertEqual(size, 5)
        var bytes = [UInt8](repeating: 0, count: size)
        XCTAssertEqual(
            ylf_copy_stream_codec_config(context, streamIndex, &bytes, bytes.count),
            0
        )
        XCTAssertEqual(bytes, [0x11, 0x88, 0x56, 0xe5, 0x00])
    }

    func testCreatesH264FormatAndZeroCopySampleBuffer() throws {
        var (context, mediaInfo) = try open("h264_aac")
        defer { ylf_close(&context) }

        var videoIndex: Int32?
        for index in 0..<mediaInfo.stream_count {
            var stream = YLFStreamInfo()
            XCTAssertEqual(ylf_copy_stream_info(context, index, &stream), 0)
            if stream.kind == 1 {
                videoIndex = stream.index
            }
        }
        let streamIndex = try XCTUnwrap(videoIndex)
        var unmanagedFormat: Unmanaged<CMVideoFormatDescription>?
        XCTAssertEqual(
            ylf_copy_video_format_description(context, streamIndex, &unmanagedFormat),
            0
        )
        let format = try XCTUnwrap(unmanagedFormat).takeRetainedValue()
        XCTAssertEqual(CMFormatDescriptionGetMediaSubType(format), kCMVideoCodecType_H264)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).width, 320)
        XCTAssertEqual(CMVideoFormatDescriptionGetDimensions(format).height, 180)

        var videoPacket: YLFPacketRef?
        while videoPacket == nil {
            var packet: YLFPacketRef?
            XCTAssertEqual(ylf_read_packet(context, &packet), 0)
            if let packet, ylf_packet_stream_index(packet) == streamIndex {
                videoPacket = packet
            } else {
                ylf_packet_release(&packet)
            }
        }

        var unmanagedSample: Unmanaged<CMSampleBuffer>?
        XCTAssertEqual(
            ylf_create_video_sample_buffer(&videoPacket, format, &unmanagedSample),
            0
        )
        XCTAssertNil(videoPacket)
        var sample: CMSampleBuffer? = try XCTUnwrap(unmanagedSample).takeRetainedValue()
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample!), 1)
        XCTAssertEqual(ylf_debug_outstanding_packet_count(), 1)
        sample = nil
        XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
    }

    func testCloseReleasesPacketsStillOwnedByContext() throws {
        var (context, _) = try open("h264_aac")
        var packet: YLFPacketRef?
        XCTAssertEqual(ylf_read_packet(context, &packet), 0)
        XCTAssertEqual(ylf_debug_outstanding_packet_count(), 1)

        ylf_close(&context)

        XCTAssertNil(context)
        XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
        // Closing a null handle is intentionally idempotent.
        ylf_close(&context)
    }

    func testCallbackInputReadsAndSeeksRealMkv() throws {
        let box = CallbackFixture(bytes: try Data(contentsOf: fixture("h264_aac")))
        var context: YLFMediaContextRef?
        var info = YLFMediaInfo()
        XCTAssertEqual(
            ylf_open_callbacks(
                box.opaque,
                fixtureRead,
                fixtureSeek,
                fixtureCancel,
                &context,
                &info
            ),
            Int32(YLFResultOK)
        )
        defer { ylf_close(&context) }
        XCTAssertEqual(info.stream_count, 2)
        XCTAssertGreaterThan(info.duration_us, 1_900_000)

        var packet: YLFPacketRef?
        XCTAssertEqual(ylf_read_packet(context, &packet), Int32(YLFResultOK))
        XCTAssertNotNil(packet)
        ylf_packet_release(&packet)
        XCTAssertEqual(ylf_seek(context, 900_000), Int32(YLFResultOK))
        XCTAssertEqual(ylf_read_packet(context, &packet), Int32(YLFResultOK))
        ylf_packet_release(&packet)
        XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
    }

    func testCallbackCloseCancelsSourceAndReleasesPackets() throws {
        let box = CallbackFixture(bytes: try Data(contentsOf: fixture("h264_aac")))
        var context: YLFMediaContextRef?
        var info = YLFMediaInfo()
        XCTAssertEqual(
            ylf_open_callbacks(
                box.opaque,
                fixtureRead,
                fixtureSeek,
                fixtureCancel,
                &context,
                &info
            ),
            Int32(YLFResultOK)
        )
        var packet: YLFPacketRef?
        XCTAssertEqual(ylf_read_packet(context, &packet), Int32(YLFResultOK))
        XCTAssertEqual(ylf_debug_outstanding_packet_count(), 1)

        ylf_close(&context)

        XCTAssertEqual(box.cancelCount, 1)
        XCTAssertEqual(ylf_debug_outstanding_packet_count(), 0)
    }

    func testCallbackReadFailureMapsDistinctly() {
        let box = CallbackFixture(bytes: Data([0x1a, 0x45, 0xdf, 0xa3]))
        box.failReads = true
        var context: YLFMediaContextRef?
        var info = YLFMediaInfo()

        XCTAssertEqual(
            ylf_open_callbacks(
                box.opaque,
                fixtureRead,
                fixtureSeek,
                fixtureCancel,
                &context,
                &info
            ),
            Int32(YLFResultCallbackFailed)
        )
        XCTAssertNil(context)
        XCTAssertEqual(box.cancelCount, 1)
    }

    func testCallbackRejectsNonMatroskaBytes() {
        let box = CallbackFixture(bytes: Data(repeating: 0x41, count: 128 * 1024))
        var context: YLFMediaContextRef?
        var info = YLFMediaInfo()

        XCTAssertEqual(
            ylf_open_callbacks(
                box.opaque,
                fixtureRead,
                fixtureSeek,
                fixtureCancel,
                &context,
                &info
            ),
            Int32(YLFResultUnsupportedContainer)
        )
        XCTAssertNil(context)
        XCTAssertEqual(box.cancelCount, 1)
    }
}
