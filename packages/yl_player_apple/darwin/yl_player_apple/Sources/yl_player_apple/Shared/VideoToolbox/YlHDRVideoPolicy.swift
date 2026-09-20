import CoreMedia
import CoreVideo

/// Choose precision from the decoded content, never from an app's display name.
enum YlHDRVideoPolicy {
  static func isHDR(_ format: CMVideoFormatDescription) -> Bool {
    if CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC { return true }
    let transfer = CMFormatDescriptionGetExtension(format,
      extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
    return transfer == kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String
      || transfer == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String
  }

  static func pixelFormat(for format: CMVideoFormatDescription) -> OSType {
    guard isHDR(format) else { return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange }
    let fullRange = CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_DolbyVisionHEVC
      || (CMFormatDescriptionGetExtension(format,
        extensionKey: kCMFormatDescriptionExtension_FullRangeVideo) as? Bool == true)
    return fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
      : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
  }
}
