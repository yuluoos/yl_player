/// Ordinary HEVC random access starts without references from the preceding GOP.
/// Keep continuous CRA leading pictures, but omit RASL when starting at CRA/BLA.
/// Owned by the demux worker and reset whenever its video resource is installed.
struct YlHEVCRandomAccessGate {
  private var firstPicture = true
  private var discardRasl = false

  mutating func shouldDiscard(_ bytes: UnsafeRawBufferPointer, nalLengthBytes: Int) -> Bool {
    guard [1, 2, 4].contains(nalLengthBytes) else { return false }
    var offset = 0
    var pictureType: UInt8?
    // Validate the complete access unit before changing state or discarding it.
    // Malformed input stays on the existing decoder error path.
    while offset < bytes.count {
      guard bytes.count - offset >= nalLengthBytes else { return false }
      var size = 0
      for index in 0..<nalLengthBytes { size = (size << 8) | Int(bytes[offset + index]) }
      offset += nalLengthBytes
      guard size >= 2, size <= bytes.count - offset else { return false }
      let first = bytes[offset], second = bytes[offset + 1]
      guard first & 0x80 == 0, second & 7 != 0,
            first & 1 == 0, second >> 3 == 0 else { return false }
      let type = (first >> 1) & 63
      if type <= 31 {
        if let pictureType, pictureType != type { return false }
        pictureType = type
      }
      offset += size
    }
    guard let pictureType else { return false }
    if (16...21).contains(pictureType) {
      discardRasl = firstPicture || pictureType != 21
    }
    firstPicture = false
    return discardRasl && (pictureType == 8 || pictureType == 9)
  }
}
