import Foundation
// Sixteen vertical monochrome bars: 0xA5 followed by the 10 Hz frame number.
func decodeCaptureMarker(_ values: [UInt8]) -> Int? {
  guard values.count == 16 else { return nil }
  var word = 0
  for value in values {
    guard value < 64 || value > 192 else { return nil }
    word = (word << 1) | (value > 192 ? 1 : 0)
  }
  guard word >> 8 == 0xA5, word & 255 < 120 else { return nil }
  return word & 255
}
