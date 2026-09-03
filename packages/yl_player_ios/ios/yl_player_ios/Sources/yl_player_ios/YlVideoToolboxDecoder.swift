import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import YlFFmpegBridge

struct YlVTDecodedImage {
  let status: OSStatus
  let pixelBuffer: CVPixelBuffer?
  let pts: CMTime
  let duration: CMTime
  let keyframe: Bool
  let generation: UInt64
  let ownershipToken: AnyObject?
}

protocol YlVTSession: AnyObject {
  var usesHardwareDecoder: Bool { get }
  func decode(_ sample: CMSampleBuffer, generation: UInt64) -> OSStatus
  func flush()
  func invalidate()
}

protocol YlVTSessionFactory {
  func makeSession(
    formatDescription: CMVideoFormatDescription,
    output: @escaping (YlVTDecodedImage) -> Void
  ) throws -> YlVTSession
}

struct YlVideoFrame {
  let pixelBuffer: CVPixelBuffer
  let ptsUs: Int64
  let durationUs: Int64
  let keyframe: Bool
  let generation: UInt64
  let ownershipToken: AnyObject?
}

protocol YlVideoToolboxDecoding: AnyObject {
  func decode(sample: CMSampleBuffer, generation: UInt64)
  func flush()
  func dispose()
}

final class YlVideoToolboxDecoder: YlVideoToolboxDecoding {
  private let lock = NSLock()
  private let onFrame: (YlVideoFrame) -> Void
  private let onError: (NativePlayerError) -> Void
  private let outputRelay: YlVTOutputRelay
  private var session: YlVTSession?
  private var activeGeneration: UInt64?
  private var disposed = false

  init(
    formatDescription: CMVideoFormatDescription,
    factory: YlVTSessionFactory = YlHardwareVTSessionFactory(),
    onFrame: @escaping (YlVideoFrame) -> Void,
    onError: @escaping (NativePlayerError) -> Void
  ) throws {
    self.onFrame = onFrame
    self.onError = onError
    let outputRelay = YlVTOutputRelay()
    self.outputRelay = outputRelay
    session = try factory.makeSession(
      formatDescription: formatDescription,
      output: { image in outputRelay.handle(image) }
    )
    outputRelay.decoder = self
  }

  static func makeFormatDescription(
    context: YLFMediaContextRef?,
    streamIndex: Int32
  ) throws -> CMVideoFormatDescription {
    var unmanagedDescription: Unmanaged<CMVideoFormatDescription>?
    let result = ylf_copy_video_format_description(
      context,
      streamIndex,
      &unmanagedDescription
    )
    guard result == YLFResultOK, let unmanagedDescription else {
      throw NativePlayerError(
        category: "decoder",
        code: "decoder.video_configuration_invalid",
        message: "The video codec configuration is invalid."
      )
    }
    return unmanagedDescription.takeRetainedValue()
  }

  static func makeFormatDescription(
    codec: Int32,
    configuration: [UInt8]
  ) throws -> CMVideoFormatDescription {
    var unmanagedDescription: Unmanaged<CMVideoFormatDescription>?
    let result = configuration.withUnsafeBytes { bytes in
      ylf_copy_video_format_description_from_codec_config(
        codec,
        bytes.bindMemory(to: UInt8.self).baseAddress,
        bytes.count,
        &unmanagedDescription
      )
    }
    guard result == YLFResultOK, let unmanagedDescription else {
      throw NativePlayerError(
        category: "decoder",
        code: "decoder.video_configuration_invalid",
        message: "The video codec configuration is invalid."
      )
    }
    return unmanagedDescription.takeRetainedValue()
  }

  func decode(sample: CMSampleBuffer, generation: UInt64) {
    lock.lock()
    guard !disposed, let session else {
      lock.unlock()
      return
    }
    activeGeneration = generation
    lock.unlock()

    let status = session.decode(sample, generation: generation)
    if status != noErr {
      onError(NativePlayerError(
        category: "decoder",
        code: "decoder.video_decode_failed",
        message: "VideoToolbox rejected a compressed video sample.",
        diagnostic: "OSStatus \(status)"
      ))
    }
  }

  func flush() {
    lock.lock()
    guard !disposed else {
      lock.unlock()
      return
    }
    activeGeneration = nil
    let session = session
    lock.unlock()
    session?.flush()
  }

  func dispose() {
    lock.lock()
    guard !disposed else {
      lock.unlock()
      return
    }
    disposed = true
    activeGeneration = nil
    let session = session
    self.session = nil
    lock.unlock()
    session?.invalidate()
  }

  fileprivate func handle(_ image: YlVTDecodedImage) {
    lock.lock()
    let acceptsOutput = !disposed && activeGeneration == image.generation
    lock.unlock()
    guard acceptsOutput else { return }

    guard image.status == noErr, let pixelBuffer = image.pixelBuffer else {
      onError(NativePlayerError(
        category: "decoder",
        code: "decoder.video_decode_failed",
        message: "VideoToolbox failed to decode a video frame.",
        diagnostic: "OSStatus \(image.status)"
      ))
      return
    }

    onFrame(YlVideoFrame(
      pixelBuffer: pixelBuffer,
      ptsUs: Self.microseconds(image.pts),
      durationUs: Self.microseconds(image.duration, unknown: 0),
      keyframe: image.keyframe,
      generation: image.generation,
      ownershipToken: image.ownershipToken
    ))
  }

  private static func microseconds(_ time: CMTime, unknown: Int64 = .min) -> Int64 {
    guard time.isValid, !time.isIndefinite else { return unknown }
    return CMTimeConvertScale(time, timescale: 1_000_000, method: .default).value
  }

  deinit {
    dispose()
  }
}

private final class YlVTOutputRelay {
  weak var decoder: YlVideoToolboxDecoder?

  func handle(_ image: YlVTDecodedImage) {
    decoder?.handle(image)
  }
}

private final class YlVTFrameContext {
  let generation: UInt64
  let keyframe: Bool

  init(generation: UInt64, keyframe: Bool) {
    self.generation = generation
    self.keyframe = keyframe
  }
}

private final class YlVTOutputContext {
  let output: (YlVTDecodedImage) -> Void

  init(output: @escaping (YlVTDecodedImage) -> Void) {
    self.output = output
  }
}

private let ylVTOutputCallback: VTDecompressionOutputCallback = {
  outputReference,
  sourceFrameReference,
  status,
  _,
  imageBuffer,
  presentationTimeStamp,
  presentationDuration in
  guard let outputReference, let sourceFrameReference else { return }
  let output = Unmanaged<YlVTOutputContext>
    .fromOpaque(outputReference)
    .takeUnretainedValue()
  let frame = Unmanaged<YlVTFrameContext>
    .fromOpaque(sourceFrameReference)
    .takeRetainedValue()
  output.output(YlVTDecodedImage(
    status: status,
    pixelBuffer: imageBuffer,
    pts: presentationTimeStamp,
    duration: presentationDuration,
    keyframe: frame.keyframe,
    generation: frame.generation,
    ownershipToken: nil
  ))
}

final class YlHardwareVTSessionFactory: YlVTSessionFactory {
  func makeSession(
    formatDescription: CMVideoFormatDescription,
    output: @escaping (YlVTDecodedImage) -> Void
  ) throws -> YlVTSession {
    let codec = CMFormatDescriptionGetMediaSubType(formatDescription)
    guard codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC,
          VTIsHardwareDecodeSupported(codec) else {
      throw Self.hardwareUnavailable(status: nil)
    }

    let outputContext = YlVTOutputContext(output: output)
    var callback = VTDecompressionOutputCallbackRecord(
      decompressionOutputCallback: ylVTOutputCallback,
      decompressionOutputRefCon: Unmanaged.passUnretained(outputContext).toOpaque()
    )
    // String keys preserve the hardware-required contract on iOS 15/16 where
    // the public constants are SDK-annotated as iOS 17+.
    let decoderSpecification = [
      "RequireHardwareAcceleratedVideoDecoder" as CFString: kCFBooleanTrue as Any,
    ] as CFDictionary
    let imageAttributes = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ] as CFDictionary
    var rawSession: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: formatDescription,
      decoderSpecification: decoderSpecification,
      imageBufferAttributes: imageAttributes,
      outputCallback: &callback,
      decompressionSessionOut: &rawSession
    )
    guard status == noErr, let rawSession else {
      throw Self.hardwareUnavailable(status: status)
    }

    var hardwareValue: CFTypeRef?
    let propertyStatus = VTSessionCopyProperty(
      rawSession,
      key: "UsingHardwareAcceleratedVideoDecoder" as CFString,
      allocator: kCFAllocatorDefault,
      valueOut: &hardwareValue
    )
    let usesHardware = propertyStatus == noErr && hardwareValue as? Bool == true
    guard usesHardware else {
      VTDecompressionSessionInvalidate(rawSession)
      throw Self.hardwareUnavailable(status: propertyStatus)
    }
    return YlHardwareVTSession(
      session: rawSession,
      outputContext: outputContext,
      usesHardwareDecoder: true
    )
  }

  private static func hardwareUnavailable(status: OSStatus?) -> NativePlayerError {
    NativePlayerError(
      category: "decoder",
      code: "decoder.video_hardware_unavailable",
      message: "A hardware H.264/HEVC decoder is unavailable.",
      diagnostic: status.map { "OSStatus \($0)" }
    )
  }
}

private final class YlHardwareVTSession: YlVTSession {
  let usesHardwareDecoder: Bool
  private let outputContext: YlVTOutputContext
  private var session: VTDecompressionSession?
  private let lock = NSLock()

  init(
    session: VTDecompressionSession,
    outputContext: YlVTOutputContext,
    usesHardwareDecoder: Bool
  ) {
    self.session = session
    self.outputContext = outputContext
    self.usesHardwareDecoder = usesHardwareDecoder
  }

  func decode(_ sample: CMSampleBuffer, generation: UInt64) -> OSStatus {
    lock.lock()
    guard let session else {
      lock.unlock()
      return kVTInvalidSessionErr
    }
    let keyframe = Self.isKeyframe(sample)
    let frameReference = Unmanaged.passRetained(
      YlVTFrameContext(generation: generation, keyframe: keyframe)
    )
    var infoFlags = VTDecodeInfoFlags()
    let status = VTDecompressionSessionDecodeFrame(
      session,
      sampleBuffer: sample,
      flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
      frameRefcon: frameReference.toOpaque(),
      infoFlagsOut: &infoFlags
    )
    lock.unlock()
    if status != noErr {
      frameReference.release()
    }
    return status
  }

  func flush() {
    lock.lock()
    guard let session else {
      lock.unlock()
      return
    }
    VTDecompressionSessionFinishDelayedFrames(session)
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    lock.unlock()
  }

  func invalidate() {
    lock.lock()
    guard let session else {
      lock.unlock()
      return
    }
    VTDecompressionSessionFinishDelayedFrames(session)
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    VTDecompressionSessionInvalidate(session)
    self.session = nil
    lock.unlock()
    withExtendedLifetime(outputContext) {}
  }

  private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
    guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sample,
      createIfNecessary: false
    ),
          CFArrayGetCount(attachments) > 0,
          let dictionary = CFArrayGetValueAtIndex(attachments, 0) else {
      return true
    }
    return !CFDictionaryContainsKey(
      unsafeBitCast(dictionary, to: CFDictionary.self),
      Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque()
    )
  }

  deinit {
    invalidate()
  }
}
