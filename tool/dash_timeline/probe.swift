import AVFoundation
import CoreVideo
import Foundation

// Test-only direct HLS feasibility probe. Never used by the production player.
@main struct TimelineProbe {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2, let url = URL(string: CommandLine.arguments[1]) else {
            fatalError("Usage: timeline-probe http://127.0.0.1:PORT/baseline.m3u8")
        }
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.play()
        for _ in 0..<300 {
            if item.status != .unknown { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        var rows: [[String: Any]] = []
        let seeks = url.lastPathComponent == "baseline.m3u8" ? [0.5, 3.8, 4.0, 4.2, 7.5] : [0.5, 2.5, 3.45, 3.8]
        if item.status == .readyToPlay {
            for target in seeks {
                player.pause()
                let ok = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                var row: [String: Any] = ["requested": target, "seekFinished": ok]
                for _ in 0..<100 {
                    var display = CMTime.invalid
                    if let buffer = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: &display) {
                        CVPixelBufferLockBaseAddress(buffer, .readOnly)
                        if let base = CVPixelBufferGetBaseAddress(buffer) {
                            let offset = CVPixelBufferGetHeight(buffer)/2 * CVPixelBufferGetBytesPerRow(buffer) + CVPixelBufferGetWidth(buffer)/2 * 4
                            let p = base.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
                            row["rgb"] = [Int(p[2]), Int(p[1]), Int(p[0])]
                        }
                        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
                        row["displayPTS"] = display.seconds
                        row["playerTime"] = player.currentTime().seconds
                        break
                    }
                    try await Task.sleep(nanoseconds: 20_000_000)
                }
                rows.append(row)
            }
        }
        player.pause()
        var report: [String: Any] = ["fixture": url.lastPathComponent, "status": item.status.rawValue, "samples": rows,
                                  "scope": "macOS AVPlayer direct HLS image probe; muted, no audio tap / audible sync evidence"]
        if item.duration.seconds.isFinite { report["duration"] = item.duration.seconds }
        if let error = item.error { report["error"] = String(describing: error) }
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        player.replaceCurrentItem(with: nil)
    }
}
