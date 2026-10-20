import Foundation
@main struct MarkerTests {
  static func main() {
    func pixels(_ value: Int) -> [UInt8] { (0..<16).map { value & (1 << (15-$0)) == 0 ? 16 : 235 } }
    for frame in [0,1,49,50,119] {
      precondition(decodeCaptureMarker(pixels(0xA500|frame)) == frame, "owned frame must decode")
    }
    precondition(decodeCaptureMarker(pixels(0xB500)) == nil)
    precondition(decodeCaptureMarker(Array(repeating: 0, count: 16)) == nil)
    precondition(decodeCaptureMarker(Array(repeating: 255, count: 16)) == nil)
    precondition(decodeCaptureMarker([1,2]) == nil)
    var ambiguous=pixels(0xA532); ambiguous[10]=128
    precondition(decodeCaptureMarker(ambiguous) == nil)
    precondition(decodeCaptureMarker(pixels(0xA5FF)) == nil)
    print("capture marker: 11 checks passed")
  }
}
