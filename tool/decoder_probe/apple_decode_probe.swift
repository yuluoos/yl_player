import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

struct Frame: Decodable { let data: Data; let ptsUs: Int64; let durationUs: Int64 }
struct Fixture: Decodable {
  let caseId: String; let codec: String; let width: Int32; let height: Int32
  let configuration: Data; let frames: [Frame]
}
final class Output {
  let lock = NSLock()
  let width: Int; let height: Int
  var count = 0; var errors = 0; var geometryErrors = 0; var formats = Set<String>()
  init(_ fixture: Fixture) { width = Int(fixture.width); height = Int(fixture.height) }
  func receive(_ status: OSStatus, _ image: CVImageBuffer?) {
    lock.lock(); defer { lock.unlock() }
    guard status == noErr, let image else { errors += 1; return }
    count += 1
    if CVPixelBufferGetWidth(image) != width || CVPixelBufferGetHeight(image) != height { geometryErrors += 1 }
    let f = CVPixelBufferGetPixelFormatType(image)
    formats.insert(String(bytes: [UInt8((f >> 24) & 255), UInt8((f >> 16) & 255), UInt8((f >> 8) & 255), UInt8(f & 255)], encoding: .ascii) ?? "none")
  }
}
func sample(_ frame: Frame, _ format: CMVideoFormatDescription) throws -> CMSampleBuffer {
  var block: CMBlockBuffer?
  guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
    blockLength: frame.data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
    offsetToData: 0, dataLength: frame.data.count, flags: 0, blockBufferOut: &block) == noErr,
    let block else { throw ProbeError.invalid }
  let copied = frame.data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!,
    blockBuffer: block, offsetIntoDestination: 0, dataLength: frame.data.count) }
  var timing = CMSampleTimingInfo(duration: CMTime(value: frame.durationUs, timescale: 1_000_000),
    presentationTimeStamp: CMTime(value: frame.ptsUs, timescale: 1_000_000), decodeTimeStamp: .invalid)
  var size = frame.data.count; var buffer: CMSampleBuffer?
  guard copied == noErr, CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
    formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
    sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer) == noErr,
    let buffer else { throw ProbeError.invalid }
  return buffer
}
enum ProbeError: Error { case invalid }
func run(_ f: Fixture, _ policy: String, _ generation: Int) throws {
  let codec = f.codec == "av1" ? kCMVideoCodecType_AV1 : kCMVideoCodecType_H264
  VTRegisterSupplementalVideoDecoderIfAvailable(codec)
  let hint = VTIsHardwareDecodeSupported(codec)
  var format: CMVideoFormatDescription?
  let atom = f.codec == "av1" ? "av1C" : "avcC"
  let ext = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: [atom: f.configuration]] as CFDictionary
  guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
    width: f.width, height: f.height, extensions: ext, formatDescriptionOut: &format) == noErr,
    let format else { throw ProbeError.invalid }
  let output = Output(f)
  var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, _, _ in
    guard let ref else { return }
    Unmanaged<Output>.fromOpaque(ref).takeUnretainedValue().receive(status, image)
  }, decompressionOutputRefCon: Unmanaged.passUnretained(output).toOpaque())
  var specification: [String: Any] = [:]
  if policy == "hardwareRequired" { specification["RequireHardwareAcceleratedVideoDecoder"] = true }
  if policy == "hardwarePreferred" { specification["EnableHardwareAcceleratedVideoDecoder"] = true }
  var session: VTDecompressionSession?
  let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
    decoderSpecification: specification as CFDictionary, imageBufferAttributes: nil,
    outputCallback: &callback, decompressionSessionOut: &session)
  var row: [String: Any] = ["caseId": f.caseId, "policy": policy, "generation": generation,
    "hardwareHint": hint, "createStatus": created, "hardwareEvidence": "unknown",
    "propertyStatus": NSNull(), "decodeStatus": NSNull(), "finishStatus": NSNull(), "waitStatus": NSNull(),
    "outputFrames": 0, "expectedFrames": f.frames.count, "callbackErrors": 0, "geometryErrors": 0, "pixelFormats": [String]()]
  if let session {
    defer { VTDecompressionSessionInvalidate(session); withExtendedLifetime(output) {} }
    guard created == noErr else { throw ProbeError.invalid }
    var property: CFTypeRef?
    let propertyStatus = VTSessionCopyProperty(session, key: "UsingHardwareAcceleratedVideoDecoder" as CFString,
      allocator: kCFAllocatorDefault, valueOut: &property)
    row["propertyStatus"] = propertyStatus
    if propertyStatus == noErr, let property, CFGetTypeID(property) == CFBooleanGetTypeID() {
      row["hardwareEvidence"] = CFEqual(property, kCFBooleanTrue) ? "hardware" : "software"
    }
    var decodeStatus: OSStatus = noErr
    for frame in f.frames {
      let result = VTDecompressionSessionDecodeFrame(session, sampleBuffer: try sample(frame, format),
        flags: [], frameRefcon: nil, infoFlagsOut: nil)
      if result != noErr { decodeStatus = result; break }
    }
    row["decodeStatus"] = decodeStatus
    row["finishStatus"] = VTDecompressionSessionFinishDelayedFrames(session)
    row["waitStatus"] = VTDecompressionSessionWaitForAsynchronousFrames(session)
    output.lock.lock()
    row["outputFrames"] = output.count; row["callbackErrors"] = output.errors
    row["geometryErrors"] = output.geometryErrors; row["pixelFormats"] = output.formats.sorted()
    output.lock.unlock()
  } else if created == noErr { throw ProbeError.invalid }
  print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
}
// Fixed owned input, bounded before copying. The outer runner enforces a process
// deadline; failed/incomplete runs never become a capability conclusion.
do {
  guard CommandLine.arguments.count == 2 else { throw ProbeError.invalid }
  let path = CommandLine.arguments[1]
  let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
  guard let size, size.intValue > 0, size.intValue <= 1_048_576 else { throw ProbeError.invalid }
  let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
  guard ["avc-control", "av1-main8", "av1-main10"].contains(fixture.caseId),
    ["h264", "av1"].contains(fixture.codec), fixture.width == 320, fixture.height == 180,
    !fixture.configuration.isEmpty, fixture.configuration.count <= 4096,
    (1...96).contains(fixture.frames.count), fixture.frames.allSatisfy({ !$0.data.isEmpty && $0.data.count <= 65_536 && $0.durationUs > 0 }) else { throw ProbeError.invalid }
  for policy in ["systemDefault", "hardwarePreferred", "hardwareRequired"] {
    for generation in 0..<2 { try run(fixture, policy, generation) }
  }
} catch {
  FileHandle.standardError.write(Data("Decoder probe input or setup failed.\n".utf8)); exit(2)
}
