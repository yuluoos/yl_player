import CoreMedia
import CoreVideo
import Foundation

@main
struct HDRPolicyTests {
  static func main() throws {
    var failures = 0
    func expect(_ condition: Bool, _ name: String) {
      if !condition { failures += 1; print("FAIL: \(name)") }
      else { print("PASS: \(name)") }
    }
    func format(_ codec: CMVideoCodecType, _ extensions: [String: Any] = [:]) -> CMVideoFormatDescription {
      var result: CMVideoFormatDescription?
      precondition(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: codec,
        width: 16, height: 16, extensions: extensions as CFDictionary, formatDescriptionOut: &result) == noErr)
      return result!
    }
    expect(YlHDRVideoPolicy.pixelFormat(for: format(kCMVideoCodecType_DolbyVisionHEVC)) == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, "Dolby Vision retains 10-bit full-range output")
    for transfer in [kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ, kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG] {
      expect(YlHDRVideoPolicy.pixelFormat(for: format(kCMVideoCodecType_HEVC,
        [kCMFormatDescriptionExtension_TransferFunction as String: transfer])) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, "HDR transfer retains 10-bit output")
    }
    expect(YlHDRVideoPolicy.pixelFormat(for: format(kCMVideoCodecType_HEVC)) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, "SDR retains existing output")
    precondition(failures == 0, "\(failures) HDR policy assertions failed")
  }
}
