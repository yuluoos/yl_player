// Acceptance-only dylib, loaded by the owned example. No screenshots persist.
// Captures exactly this process's selected window; never another application.
import AppKit
import ScreenCaptureKit
import CoreMedia
import Darwin

private func ticksUs(_ ticks: UInt64) -> UInt64 {
  var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
  return UInt64(Double(ticks) * Double(info.numer) / Double(info.denom) / 1000)
}
@_cdecl("yl_capture_clock_us") public func clockUs() -> UInt64 { ticksUs(mach_absolute_time()) }
private let lock = NSLock()
private var state = "idle"
private var rows = [[String: Any]]()
private var diagnostic: [String: Any] = [:]
private var observer: AnyObject?
private var savedFrame: NSRect?
private var savedLevel: NSWindow.Level?
private var savedBehavior: NSWindow.CollectionBehavior?
private weak var ownedWindow: NSWindow?
private func status(_ value: String) { lock.lock(); state = value; lock.unlock() }

@available(macOS 14.0, *)
private final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
  var stream: SCStream?
  @MainActor func start() async throws {
    guard Thread.isMainThread else { status("wrong-thread"); return }
    // Do not request permissions; a missing existing grant is external_missing.
    guard CGPreflightScreenCaptureAccess() else { status("permission-missing"); return }
    let windows = NSApplication.shared.windows.filter { $0.contentViewController != nil && $0.isVisible }
    guard windows.count == 1, let window = windows.first else { status("window-ambiguous"); return }
    ownedWindow = window; savedFrame = window.frame
    window.setContentSize(NSSize(width: 640, height: 400))
    // Keep only our acceptance window visible without activating another app or
    // moving the user's Space. Restore every setting during owned cleanup.
    savedLevel = window.level; savedBehavior = window.collectionBehavior
    var behavior = window.collectionBehavior.subtracting([.moveToActiveSpace, .fullScreenPrimary, .fullScreenNone])
    behavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
    behavior.subtract([.primary, .auxiliary]); behavior.insert(.canJoinAllApplications)
    window.collectionBehavior = behavior; window.level = .floating
    window.orderFrontRegardless()
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    guard let selected = content.windows.first(where: {
      $0.owningApplication?.processID == getpid() && $0.windowID == CGWindowID(window.windowNumber)
    }) else { status("window-unavailable"); return }
    let filter = SCContentFilter(desktopIndependentWindow: selected)
    let config = SCStreamConfiguration()
    config.width = 640; config.height = Int(selected.frame.height)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
    config.queueDepth = 3; config.showsCursor = false
    config.capturesAudio = false; config.ignoreShadowsSingleWindow = true
    let capture = SCStream(filter: filter, configuration: config, delegate: self)
    stream = capture
    try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "yl.owned.capture"))
    try await capture.startCapture()
    status("capturing")
  }
  func stream(_ stream: SCStream, didStopWithError error: Error) { status("capture-failed") }
  func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .screen, sample.isValid,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let info = attachments.first,
      let raw = info[.status] as? Int, raw == SCFrameStatus.complete.rawValue,
      let displayTicks = info[.displayTime] as? UInt64,
      let pixel = CMSampleBufferGetImageBuffer(sample) else { return }
    CVPixelBufferLockBaseAddress(pixel, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixel) else { return }
    let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
    let stride = CVPixelBufferGetBytesPerRow(pixel)
    guard width >= 160, height >= 100 else { status("capture-size-invalid"); return }
    let pointer = base.assumingMemoryBound(to: UInt8.self)
    // Window geometry is fixed above. 16:9 video fills its width with only
    // vertical letterboxing. Check three center rows to reject partial frames.
    var markers = [Int?]()
    var sampled = [[UInt8]]()
    for y in [height * 2 / 5, height / 2, height * 3 / 5] {
      let levels: [UInt8] = (0..<16).map { cell in
        let x = (2 * cell + 1) * width / 32
        let offset = y * stride + x * 4
        return UInt8((Int(pointer[offset]) + Int(pointer[offset+1]) + Int(pointer[offset+2])) / 3)
      }
      sampled.append(levels)
      markers.append(decodeCaptureMarker(levels))
    }
    let marker: Any = markers[0] != nil && markers.allSatisfy({ $0 == markers[0] }) ? markers[0]! : NSNull()
    let row: [String: Any] = ["displayUs": ticksUs(displayTicks), "receivedUs": clockUs(), "frame": marker]
    lock.lock(); defer { lock.unlock() }
    guard state == "capturing" || state == "starting" else { return }
    guard rows.count < 4096 else { state = "overflow"; return }
    diagnostic = ["width": width, "height": height, "levels": sampled]
    rows.append(row)
  }
}

@_cdecl("yl_capture_start") public func startCapture() {
  lock.lock()
  guard state == "idle" else { lock.unlock(); return }
  state = "starting"; lock.unlock()
  DispatchQueue.main.async {
    guard #available(macOS 14.0, *) else { status("unsupported"); return }
    let capture = Capture(); observer = capture
    Task { @MainActor in
      do { try await capture.start() } catch { status("start-failed") }
    }
  }
}
@_cdecl("yl_capture_stop") public func stopCapture() {
  DispatchQueue.main.async {
    Task { @MainActor in
      var stopped = true
      if #available(macOS 14.0, *), let capture = observer as? Capture {
        do { try await capture.stream?.stopCapture() } catch { stopped = false }
      }
      if let window = ownedWindow, let frame = savedFrame {
        if let level = savedLevel { window.level = level }
        if let behavior = savedBehavior { window.collectionBehavior = behavior }
        window.setFrame(frame, display: true)
      }
      observer = nil; status(stopped ? "stopped" : "stop-failed")
    }
  }
}
@_cdecl("yl_capture_snapshot") public func snapshotCapture() -> UnsafeMutablePointer<CChar>? {
  lock.lock(); defer { lock.unlock() }
  let result: [String: Any] = ["status": state, "rows": rows, "diagnostic": diagnostic]
  guard let data = try? JSONSerialization.data(withJSONObject: result),
    let string = String(data: data, encoding: .utf8) else { return nil }
  rows.removeAll(keepingCapacity: true)
  return strdup(string)
}
@_cdecl("yl_capture_free") public func freeCapture(_ pointer: UnsafeMutableRawPointer?) { free(pointer) }

@_cdecl("yl_capture_visibility") public func setCaptureVisibility(_ visible: Int32) {
  DispatchQueue.main.async {
    if visible == 0 { NSApplication.shared.hide(nil) }
    else { NSApplication.shared.unhideWithoutActivation(); ownedWindow?.orderFrontRegardless() }
  }
}
