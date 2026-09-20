import AVFoundation
import CoreVideo
import Foundation

@main
struct HDRSampleTests {
  static func main() throws {
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16,
      kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
      [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel) == kCVReturnSuccess)
    let rpu = Data([1, 2, 3, 4])
    CVBufferSetAttachment(pixel!, "DolbyVisionRPUData" as CFString, rpu as CFData, .shouldPropagate)
    CVBufferSetAttachment(pixel!, kCVImageBufferTransferFunctionKey,
      kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, .shouldPropagate)
    let sample = try YlSampleBufferVideoRenderer.makeSample(pixel!)
    precondition(CMSampleBufferGetImageBuffer(sample) === pixel!)
    let format = CMSampleBufferGetFormatDescription(sample)!
    precondition(CMFormatDescriptionGetExtension(format,
      extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
      == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
    precondition(CVBufferCopyAttachment(CMSampleBufferGetImageBuffer(sample)!,
      "DolbyVisionRPUData" as CFString, nil) as? Data == rpu)
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)! as NSArray
    precondition((attachments[0] as! NSDictionary)[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
    let renderer = YlSampleBufferVideoRenderer()
    var pending: CVPixelBuffer?
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &pending)
    weak var retained = pending
    renderer.publish(pending!)
    pending = nil
    precondition(retained != nil, "Retain newest frame until platform view attaches")
    renderer.clear()
    precondition(retained == nil, "Clear releases the retained frame even before view attachment")
    final class Lifetime {}
    var token: Lifetime? = Lifetime()
    weak var heldToken = token
    var retainedSample: CMSampleBuffer? = try YlSampleBufferVideoRenderer.makeSample(pixel!, retaining: token)
    token = nil
    precondition(heldToken != nil, "Display sample must retain its memory reservation")
    precondition(CMSampleBufferGetImageBuffer(retainedSample!) === pixel!)
    retainedSample = nil
    precondition(heldToken == nil, "Releasing a display sample releases its reservation, even while pixel buffer is alive")
    print("PASS: pixel identity, 10-bit buffer, PQ and RPU retained; immediate display; pending-frame lifetime")
  }
}
