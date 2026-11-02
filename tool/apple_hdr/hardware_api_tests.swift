@testable import yl_player_apple
import yl_player_media_core
import CoreMedia
import VideoToolbox

private final class Decoder: YlVideoDecoderResource {
  let hardwareEvidence: YlHardwareDecoderEvidence
  var usesHardwareDecoder: Bool { hardwareEvidence.mode == .hardware }
  var disposed = false
  init(_ mode: YlHardwareDecoderEvidence.Mode) { hardwareEvidence = .init(mode: mode) }
  func reserve(byteCount: Int, shouldCancel: () -> Bool) throws -> YlVideoDecodeReservation? { nil }
  func reserveSubmission(byteCount: Int, shouldCancel: () -> Bool) throws -> YlVideoDecodeReservation? { nil }
  func decode(sample: CMSampleBuffer, generation: UInt64, reservation: YlVideoDecodeReservation?) {}
  func drain() {}
  func flush() {}
  func dispose() { disposed = true }
}

@main
struct HardwareAPITests {
  static func main() throws {
    for value: CFTypeRef in [kCFBooleanTrue!, kCFBooleanFalse!, NSNumber(value: 2)] {
      var queries = 0
      let reader = YlVTSessionPropertyReader(copy: { _, key, output in
        queries += 1
        if #available(macOS 10.9, iOS 17.0, *) {
          precondition(key == kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder)
        } else {
          preconditionFailure("Legacy iOS queried an unavailable hardware key")
        }
        output = value
        return noErr
      })
      let evidence = reader.evidence(for: kCFBooleanTrue)
      let supported = YlVTSessionPropertyReader.isSupported
      precondition(queries == (supported ? 1 : 0))
      let expected: YlHardwareDecoderEvidence.Mode = !supported || CFGetTypeID(value) != CFBooleanGetTypeID()
        ? .unknown : (CFEqual(value, kCFBooleanTrue) ? .hardware : .software)
      precondition(evidence.mode == expected)
    }

    for policy in [YlDecoderPolicy.systemDefault, .hardwarePreferred, .hardwareRequired] {
      for mode in [YlHardwareDecoderEvidence.Mode.hardware, .unknown, .software] {
        let decoder = Decoder(mode)
        var softwareCalls = 0
        do {
          let result = try YlVideoDecoderSelection.choose(policy: policy, hardware: { decoder }, software: {
            softwareCalls += 1
            return Decoder(.software)
          })
          let accepts = mode == .hardware || (!YlVTSessionPropertyReader.isSupported && mode == .unknown && policy != .hardwareRequired)
          precondition((result === decoder) == accepts)
          precondition(decoder.disposed == !accepts)
          precondition(softwareCalls == (accepts ? 0 : 1))
        } catch let error as NativePlayerError {
          precondition(policy == .hardwareRequired && mode != .hardware)
          precondition(error.code == "decoder.unavailable")
          precondition(decoder.disposed && softwareCalls == 0)
        }
      }
    }
    print("Hardware API checks passed: property availability, CFBoolean evidence, decoder policy selection")
  }
}
