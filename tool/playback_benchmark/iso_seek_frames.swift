import AVFoundation
import QuartzCore

// Report elapsed milliseconds only after AVPlayer produces a frame at the target.
let item = AVPlayerItem(url: URL(string: CommandLine.arguments[1])!)
let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
])
item.add(output)
let player = AVPlayer(playerItem: item)
player.isMuted = true
player.play()

func waitForFrame(at position: Double, seek: Bool) {
    var ready = !seek
    let start = CACurrentMediaTime()
    if seek {
        player.seek(to: CMTime(seconds: position, preferredTimescale: 90_000),
                    toleranceBefore: .zero, toleranceAfter: .zero) { ready = $0 }
    }
    while CACurrentMediaTime() - start < 25 && item.status != .failed {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        var display = CMTime.invalid
        if ready, time.seconds >= position - 0.04, time.seconds < position + 2,
           let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &display),
           display.seconds >= position - 0.05, display.seconds < position + 2,
           CVPixelBufferGetWidth(buffer) > 0 {
            print(Int((CACurrentMediaTime() - start) * 1000))
            fflush(stdout)
            return
        }
    }
    fputs("No decoded frame at \(position)s (item time \(item.currentTime().seconds))\n", stderr)
    exit(1)
}

waitForFrame(at: 0, seek: false)
let far = max(2, floor(item.duration.seconds) - 3)
for position in [far, 1, far, 1] {
    waitForFrame(at: position, seek: true)
}
