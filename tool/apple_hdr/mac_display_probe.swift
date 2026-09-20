// Opt-in native verification. Media stays outside the repository.
import AppKit
import AVFoundation
import VideoToolbox
import YlFFmpegBridge

@main
struct HDRDisplayProbe {
  static func main() throws {
    guard CommandLine.arguments.count == 3 else {
      print("Usage: mac-display-probe MEDIA_PATH REPAIRED_HVCC_PATH")
      return
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let screen = NSScreen.screens.first { screen in
      guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
      return CGDisplayIsBuiltin(number.uint32Value) != 0
    } ?? NSScreen.main!
    let window = NSWindow(contentRect: NSRect(x: screen.frame.minX + 60,
      y: screen.frame.minY + 80, width: 960, height: 404),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "YL HDR native display verification"
    window.contentView!.wantsLayer = true
    let renderer = YlSampleBufferVideoRenderer()
    var renderError: Error?
    renderer.onFailure = { renderError = $0 }
    renderer.attach(window.contentView!.layer!)
    defer { renderer.dispose(); window.close() }
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    var context: YLFMediaContextRef?
    var info = YLFMediaInfo()
    precondition(ylf_open_local(CommandLine.arguments[1], &context, &info) == YLFResultOK)
    defer { ylf_close(&context) }
    var videoIndex: Int32 = -1
    for index in 0..<info.stream_count {
      var stream = YLFStreamInfo()
      if ylf_copy_stream_info(context, index, &stream) == YLFResultOK,
         stream.kind == Int32(YLFStreamVideo) { videoIndex = index; break }
    }
    precondition(videoIndex >= 0)
    let hvcc = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    var description: Unmanaged<CMVideoFormatDescription>?
    let result = hvcc.withUnsafeBytes { bytes in
      ylf_copy_video_format_description_with_codec_config(context, videoIndex,
        bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &description)
    }
    precondition(result == YLFResultOK)
    let format = description!.takeRetainedValue()
    let pixelFormat = YlHDRVideoPolicy.pixelFormat(for: format)
    var session: VTDecompressionSession?
    precondition(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
      formatDescription: format, decoderSpecification: nil,
      imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: pixelFormat,
        kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
      outputCallback: nil, decompressionSessionOut: &session) == noErr)
    defer { VTDecompressionSessionInvalidate(session!) }
    var decoded = 0
    for _ in 0..<32 {
      var packet: YLFPacketRef?
      let read = ylf_read_packet(context, &packet)
      defer { ylf_packet_release(&packet) }
      guard read == YLFResultOK else { break }
      guard ylf_packet_stream_index(packet) == videoIndex else { continue }
      var sample: Unmanaged<CMSampleBuffer>?
      precondition(ylf_create_video_sample_buffer(&packet, format, &sample) == YLFResultOK)
      let status = VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample!.takeRetainedValue(),
        flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
        guard status == noErr, let image else { return }
        decoded += 1
        let rpu = CVBufferCopyAttachment(image, "DolbyVisionRPUData" as CFString, nil) as? Data
        print("decodedPixelFormat=\(CVPixelBufferGetPixelFormatType(image)) RPUBytes=\(rpu?.count ?? 0)")
        DispatchQueue.main.async { renderer.publish(image) }
      }
      precondition(status == noErr)
      break
    }
    VTDecompressionSessionFinishDelayedFrames(session!)
    VTDecompressionSessionWaitForAsynchronousFrames(session!)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 5))
    let displayLayer = window.contentView!.layer!.sublayers?.first as? AVSampleBufferDisplayLayer
    print("decoded=\(decoded) layerStatus=\(displayLayer?.status.rawValue ?? -1) renderError=\(renderError != nil) currentEDR=\(window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 0)")
    precondition(decoded > 0 && displayLayer?.status == .rendering && renderError == nil)
  }
}
