import AppKit
import AVFoundation
import CoreMedia
import CoreVideo

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 240), styleMask: [.titled], backing: .buffered, defer: false)
window.title = "原生显示对照：普通缓冲 / IOSurface"
window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications]
window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
let area = NSScreen.main!.visibleFrame
window.setFrameOrigin(NSPoint(x: area.maxX - window.frame.width - 24, y: area.maxY - window.frame.height - 24))
let view = window.contentView!; view.wantsLayer = true
let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let frameCount = 4320
let queue = DispatchQueue(label: "surface.comparison", qos: .userInitiated)
let host = CMClockGetHostTimeClock()
var base: CMTimebase?
precondition(CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: host, timebaseOut: &base) == 0)
final class Channel {
  let name: String
  let layer = AVSampleBufferDisplayLayer()
  var pixels: [CVPixelBuffer] = []
  var format: CMVideoFormatDescription?
  var count = 0
  var minLead = 1.0
  var lastDrops = 0
  init(_ surface: Bool, x: CGFloat) {
    name = surface ? "iosurface" : "ordinary"
    layer.frame = CGRect(x: x, y: 30, width: 320, height: 180)
    layer.controlTimebase = base
    view.layer!.addSublayer(layer)
    let attrs: CFDictionary? = surface ? [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary : nil
    raw.withUnsafeBytes { ptr in
      for n in 0..<96 {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &buffer) == 0)
        let pixel = buffer!
        precondition((CVPixelBufferGetIOSurface(pixel) != nil) == surface)
        CVPixelBufferLockBaseAddress(pixel, [])
        for plane in 0..<2 {
          let addr = CVPixelBufferGetBaseAddressOfPlane(pixel, plane)!
          let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
          for row in 0..<CVPixelBufferGetHeightOfPlane(pixel, plane) {
            memcpy(addr + row * stride, ptr.baseAddress! + n * 86400 + plane * 57600 + row * 320, 320)
          }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        CVBufferSetAttachment(pixel, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        pixels.append(pixel)
      }
    }
    precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels[0], formatDescriptionOut: &format) == 0)
  }
  func enqueue() {
    let now = CMTimeGetSeconds(CMTimebaseGetTime(base!))
    while count < frameCount && Double(count)/24 <= now + 0.050 && layer.sampleBufferRenderer.isReadyForMoreMediaData {
      var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 24), presentationTimeStamp: CMTime(value: Int64(count), timescale: 24), decodeTimeStamp: .invalid)
      var sample: CMSampleBuffer?
      precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels[count % 96], formatDescription: format!, sampleTiming: &timing, sampleBufferOut: &sample) == 0)
      if count > 0 { minLead = min(minLead, Double(count)/24 - CMTimeGetSeconds(CMTimebaseGetTime(base!))) }
      layer.sampleBufferRenderer.enqueue(sample!); count += 1
    }
  }
}
let channels = [Channel(false, x: 20), Channel(true, x: 360)]
let timer = DispatchSource.makeTimerSource(queue: queue)
var reverse = false
// Alternate order to avoid giving one buffer type a consistent enqueue advantage.
timer.setEventHandler {
  for channel in (reverse ? Array(channels.reversed()) : channels) { channel.enqueue() }
  reverse.toggle()
}
var started = false
var terminal = Set<String>()
var invalidExposure = false
let visibility = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { _ in
  if started && !window.occlusionState.contains(.visible) { invalidExposure = true; print("CONTROL_OCCLUDED") }
}
window.orderFrontRegardless()
CMTimebaseSetTime(base!, time: .zero)
Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { waiter in
  guard window.occlusionState.contains(.visible) else { return }
  waiter.invalidate(); queue.sync { channels.forEach { $0.enqueue() } }
  DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    for channel in channels {
      channel.layer.sampleBufferRenderer.loadVideoPerformanceMetrics { m in
        if let m { print("CONTROL_PREFLIGHT", channel.name, m.totalNumberOfFrames, m.numberOfDroppedFrames); fflush(stdout) }
      }
    }
    CMTimebaseSetRateAndAnchorTime(base!, rate: 1, anchorTime: .zero, immediateSourceTime: CMClockGetTime(host))
    started = true
    timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1)); timer.resume()
  }
}
Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
  guard started else { return }
  for channel in channels {
    channel.layer.sampleBufferRenderer.loadVideoPerformanceMetrics { m in
      DispatchQueue.main.async {
        let m = m!
        let stats = queue.sync { (channel.count, channel.minLead) }
        print("CONTROL", channel.name, ProcessInfo.processInfo.systemUptime, stats.0, stats.1, m.totalNumberOfFrames, m.numberOfDroppedFrames, m.numberOfCorruptedFrames, window.occlusionState.contains(.visible)); fflush(stdout)
        channel.lastDrops = m.numberOfDroppedFrames
        if m.totalNumberOfFrames >= frameCount { terminal.insert(channel.name) }
        if terminal.count == 2 { exit(invalidExposure ? 2 : 0) }
      }
    }
  }
}
app.run()
