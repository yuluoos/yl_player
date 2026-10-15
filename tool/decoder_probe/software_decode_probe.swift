import Foundation
import CoreMedia
import CoreVideo
import Darwin
import YlFFmpegBridge

private struct Frame: Decodable { let data: Data; let ptsUs: Int64; let durationUs: Int64 }
private struct Fixture: Decodable { let width: Int32; let height: Int32; let frames: [Frame] }
private enum ProbeError: Error { case invalid(String) }
private func require(_ condition: Bool, _ message: String) throws {
  if !condition { throw ProbeError.invalid(message) }
}
private func monotonic() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
private func wait(until target: UInt64) {
  while true {
    let now = monotonic()
    if now >= target { return }
    let remaining = target - now
    Thread.sleep(forTimeInterval: Double(min(remaining, 20_000_000)) / 1e9)
  }
}
private func sample(_ frame: Frame, format: CMVideoFormatDescription) throws -> CMSampleBuffer {
  var block: CMBlockBuffer?
  try require(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
    blockLength: frame.data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
    offsetToData: 0, dataLength: frame.data.count, flags: 0, blockBufferOut: &block) == noErr, "block")
  let copied = frame.data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
    blockBuffer: block!, offsetIntoDestination: 0, dataLength: frame.data.count) }
  var timing = CMSampleTimingInfo(duration: CMTime(value: frame.durationUs, timescale: 1_000_000),
    presentationTimeStamp: CMTime(value: frame.ptsUs, timescale: 1_000_000), decodeTimeStamp: .invalid)
  var size = frame.data.count; var result: CMSampleBuffer?
  try require(copied == noErr && CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
    dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
    sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
    sampleBufferOut: &result) == noErr && result != nil, "sample")
  return result!
}
private func snapshot(start: UInt64, slot: Int) -> [String: Any] {
  var cpu = timespec()
  let cpuOK = clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &cpu) == 0
  var memory = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
  let memoryOK = withUnsafeMutablePointer(to: &memory) { pointer in
    pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  } == KERN_SUCCESS
  let thermal: String
  switch ProcessInfo.processInfo.thermalState {
  case .nominal: thermal = "nominal"
  case .fair: thermal = "fair"
  case .serious: thermal = "serious"
  case .critical: thermal = "critical"
  @unknown default: thermal = "unknown"
  }
  return ["monotonicNs": monotonic() - start, "slot": slot,
    "cpuNs": cpuOK ? UInt64(cpu.tv_sec) * 1_000_000_000 + UInt64(cpu.tv_nsec) as Any : NSNull(),
    "rssBytes": memoryOK ? memory.resident_size as Any : NSNull(),
    "footprintBytes": memoryOK ? memory.phys_footprint as Any : NSNull(),
    "thermal": thermal, "lowPower": ProcessInfo.processInfo.isLowPowerModeEnabled]
}
private final class Sampler: @unchecked Sendable {
  let lock = NSLock(); var values = [[String: Any]]()
  func append(_ value: [String: Any]) { lock.lock(); values.append(value); lock.unlock() }
}
private func checkImage(_ image: CVPixelBuffer, pts: CMTime) throws {
  try require(CVPixelBufferGetWidth(image) == 320 && CVPixelBufferGetHeight(image) == 180 &&
    CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "output format")
  CVPixelBufferLockBaseAddress(image, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
  let y = CVPixelBufferGetBaseAddressOfPlane(image, 0)!.assumingMemoryBound(to: UInt8.self)
  let uv = CVPixelBufferGetBaseAddressOfPlane(image, 1)!.assumingMemoryBound(to: UInt8.self)
  let l = Int(y[90 * CVPixelBufferGetBytesPerRowOfPlane(image, 0) + 160])
  let index = 45 * CVPixelBufferGetBytesPerRowOfPlane(image, 1) + 160
  let actual = [l, Int(uv[index]), Int(uv[index+1])]
  let second = min(3, max(0, Int(CMTimeGetSeconds(pts))))
  let expected = [[81,90,240], [145,54,34], [41,240,110], [235,128,128]][second]
  try require(zip(actual, expected).allSatisfy { abs($0-$1) <= 3 }, "actual output marker \(second): \(actual)")
}
private func run() throws {
  try require(CommandLine.arguments.count == 3, "arguments")
  let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
  try require(fixture.frames.count == 96 && fixture.width == 320 && fixture.height == 180, "fixture")
  // No decode or decoder construction occurs before this process's idle baseline.
  let start = monotonic(), sampler = Sampler(), done = DispatchGroup()
  done.enter()
  DispatchQueue.global(qos: .userInitiated).async {
    for slot in 0...64 {
      wait(until: start + UInt64(slot) * 250_000_000)
      let value = snapshot(start: start, slot: slot)
      sampler.append(value)
      if let data = try? JSONSerialization.data(withJSONObject: ["sample": value], options: [.sortedKeys]),
        let line = String(data: data, encoding: .utf8) { print(line); fflush(stdout) }
    }
    done.leave()
  }
  var context: YLFMediaContextRef?
  var decoder: YLFSoftwareVideoDecoderRef?
  defer { ylf_software_video_free(decoder); ylf_close(&context) }
  wait(until: start + 2_000_000_000)
  var info = YLFMediaInfo()
  try require(ylf_open_local(CommandLine.arguments[2], &context, &info) == 0, "open")
  var video: Int32 = -1
  for i in 0..<info.stream_count {
    var stream = YLFStreamInfo()
    try require(ylf_copy_stream_info(context, i, &stream) == 0, "stream")
    if stream.codec == YLFCodecAV1 { video = i }
  }
  try require(video >= 0, "AV1 stream")
  var configuration: YLFSoftwareVideoConfigurationRef?
  try require(ylf_software_video_copy_configuration(context, video, &configuration) == 0, "configuration")
  var descriptor = YLFSoftwareVideoDescriptor()
  let described = ylf_software_video_copy_descriptor(configuration, MemoryLayout<YLFSoftwareVideoDescriptor>.size, &descriptor)
  ylf_software_video_free_configuration(configuration)
  try require(described == 0 && descriptor.codec == YLFCodecAV1 && descriptor.profile == 0 &&
    descriptor.width == 320 && descriptor.height == 180 && descriptor.bit_depth == 8 &&
    descriptor.chroma == 420 && descriptor.fps_num == 24 && descriptor.fps_den == 1, "exact admission descriptor")
  let limits = YLFSoftwareVideoLimits(max_owned_bytes: 32*1024*1024, max_frames: 64,
    max_packet_bytes: 1024*1024, threads: 2, account_context: nil, reserve: nil, release: nil)
  try require(ylf_software_video_create(context, video, limits, &decoder) == 0 && decoder != nil, "create")
  var format: CMVideoFormatDescription?
  try require(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_AV1,
    width: 320, height: 180, extensions: nil, formatDescriptionOut: &format) == noErr, "format")
  var frames = 0
  func drain() throws -> Int32 {
    while true {
      var retained: Unmanaged<CVPixelBuffer>?
      var pts = CMTime.invalid, duration = CMTime.invalid
      let status = ylf_software_video_receive(decoder, &retained, &pts, &duration)
      if status == YLFResultWouldBlock || status == YLFResultEOF { try require(retained == nil, "unexpected image"); return status }
      try require(status == 0 && retained != nil, "receive")
      let image = retained!.takeRetainedValue()
      try checkImage(image, pts: pts); frames += 1
    }
  }
  for cycle in 0..<3 {
    if cycle > 0 { ylf_software_video_reset(decoder) }
    for (index, frame) in fixture.frames.enumerated() {
      wait(until: start + 2_000_000_000 + UInt64(cycle*96+index)*1_000_000_000/24)
      try autoreleasepool {
        let buffer = try sample(frame, format: format!)
        var result = ylf_software_video_send(decoder, buffer)
        if result == YLFResultWouldBlock { _ = try drain(); result = ylf_software_video_send(decoder, buffer) }
        try require(result == 0, "send"); _ = try drain()
      }
    }
    try require(ylf_software_video_finish(decoder) == 0 && drain() == YLFResultEOF, "finish")
  }
  wait(until: start + 14_000_000_000)
  ylf_software_video_free(decoder); decoder = nil; ylf_close(&context)
  done.wait()
  try require(frames == 288, "frame count")
  let row: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
    "status": "passed", "decodedFrames": frames, "outputMarkersVerified": true,
    "samples": sampler.values, "measurementOutput": "actual CVPixelBuffer NV12 planes; not physical display"]
  print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
}
do { try run() }
catch { fputs("Software measurement failed: \(error)\n", stderr); exit(1) }
