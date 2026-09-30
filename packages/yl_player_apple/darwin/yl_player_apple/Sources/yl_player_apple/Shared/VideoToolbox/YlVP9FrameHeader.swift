import Foundation

/// Restricted visible-frame Profile 0 header. The decoder validates the rest.
struct YlVP9FrameHeader {
  let keyframe: Bool
  let width: Int
  let height: Int
  let colorSpace: Int
  let fullRange: Bool
  var configuration: [UInt8] {
    let color: UInt8 = colorSpace == 2 ? 1 : colorSpace == 1 ? 6 : 2
    return [1, 0, 0, 0, 0, 0, 0x82 | (fullRange ? 1 : 0), color, color, color, 0, 0]
  }

  static func parse(_ bytes: UnsafeBufferPointer<UInt8>, reference: YlVP9FrameHeader? = nil) -> YlVP9FrameHeader? {
    guard !bytes.isEmpty, bytes.count <= 8 * 1024 * 1024 else { return nil }
    let marker = bytes[bytes.count - 1]
    if marker & 0xe0 == 0xc0 {
      let indexSize = 2 + (Int(marker & 7) + 1) * (Int((marker >> 3) & 3) + 1)
      if bytes.count >= indexSize && bytes[bytes.count - indexSize] == marker { return nil }
    }
    var reader = Bits(bytes: bytes)
    guard reader.read(2) == 2, reader.read(1) == 0, reader.read(1) == 0,
          reader.read(1) == 0, let frameType = reader.read(1), reader.read(1) == 1,
          let resilient = reader.read(1) else { return nil }
    let keyframe = frameType == 0
    var width: Int, height: Int, color: Int, range: Bool
    if keyframe {
      guard reader.read(24) == 0x498342, let space = reader.read(3),
            [0, 1, 2].contains(space), let full = reader.read(1),
            let w = reader.read(16), let h = reader.read(16) else { return nil }
      width = w + 1; height = h + 1; color = space; range = full == 1
    } else {
      guard let reference else { return nil }
      if resilient == 0 && reader.read(2) == nil { return nil }
      guard reader.read(8) != nil else { return nil } // refresh flags
      for _ in 0..<3 { guard reader.read(4) != nil else { return nil } } // ref index + sign bias
      var inherited = false
      for _ in 0..<3 {
        guard let found = reader.read(1) else { return nil }
        if found == 1 { inherited = true; break }
      }
      if inherited { width = reference.width; height = reference.height }
      else {
        guard let w = reader.read(16), let h = reader.read(16) else { return nil }
        width = w + 1; height = h + 1
      }
      color = reference.colorSpace; range = reference.fullRange
    }
    guard width <= 4096, height <= 2160, let renderDifferent = reader.read(1) else { return nil }
    if renderDifferent == 1 {
      guard reader.read(16) == width - 1, reader.read(16) == height - 1 else { return nil }
    }
    if let reference {
      guard width == reference.width, height == reference.height,
            color == reference.colorSpace, range == reference.fullRange else { return nil }
    }
    return .init(keyframe: keyframe, width: width, height: height, colorSpace: color, fullRange: range)
  }

  private struct Bits {
    let bytes: UnsafeBufferPointer<UInt8>
    var offset = 0
    mutating func read(_ count: Int) -> Int? {
      guard count <= bytes.count * 8 - offset else { return nil }
      var value = 0
      for _ in 0..<count {
        value = (value << 1) | Int((bytes[offset / 8] >> (7 - offset % 8)) & 1)
        offset += 1
      }
      return value
    }
  }
}

/// Opening constraints are immutable; decoder history readiness resets on seek.
struct YlVP9PacketGate {
  let opening: YlVP9FrameHeader
  private var ready = false
  init(opening: YlVP9FrameHeader) { self.opening = opening }
  mutating func reset() { ready = false }
  mutating func accepts(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
    guard let header = YlVP9FrameHeader.parse(bytes, reference: opening),
          ready || header.keyframe else { return false }
    ready = true
    return true
  }
}
