import XCTest
import YlFFmpegBridge

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
}
