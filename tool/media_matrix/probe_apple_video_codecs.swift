import Foundation
import CoreMedia
import VideoToolbox

// Capability hints only. Actual support requires a decoder session, strict
// CFBoolean hardware evidence and decoded output for the selected profile.
for (name, codec) in [("avc", kCMVideoCodecType_H264), ("hevc", kCMVideoCodecType_HEVC),
                       ("vp9", kCMVideoCodecType_VP9), ("av1", kCMVideoCodecType_AV1)] {
  let before = VTIsHardwareDecodeSupported(codec)
  VTRegisterSupplementalVideoDecoderIfAvailable(codec)
  let row: [String: Any] = ["codec": name, "hardwareHintBeforeRegistration": before,
    "hardwareHintAfterRegistration": VTIsHardwareDecodeSupported(codec), "sessionOutputVerified": false]
  print(String(data: try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), encoding: .utf8)!)
}
