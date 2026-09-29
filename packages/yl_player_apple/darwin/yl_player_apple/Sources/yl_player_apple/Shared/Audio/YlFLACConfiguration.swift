import AudioToolbox
import Foundation

/// FFmpeg exposes the 34-byte FLAC STREAMINFO; CoreAudio expects a dfLa atom.
/// Limit this path to the independently checked 16/24-bit mono/stereo layouts.
struct YlFLACConfiguration {
  let maxBlockSize: UInt32
  let formatFlags: AudioFormatFlags
  let coreAudioCookie: Data

  init?(stream: YlAudioStreamConfiguration) {
    guard stream.magicCookie.count == 34 else { return nil }
    let data = Array(stream.magicCookie)
    let minimum = Int(data[0]) << 8 | Int(data[1])
    let maximum = Int(data[2]) << 8 | Int(data[3])
    let rate = Int(data[10]) << 12 | Int(data[11]) << 4 | Int(data[12] >> 4)
    let channels = Int((data[12] >> 1) & 7) + 1
    let bits = Int(data[12] & 1) << 4 | Int(data[13] >> 4)
    guard minimum >= 16, maximum >= minimum,
          rate > 0, Double(rate) == stream.sampleRate,
          (1...2).contains(channels), channels == stream.channelCount,
          bits + 1 == 16 || bits + 1 == 24 else { return nil }
    maxBlockSize = UInt32(maximum)
    formatFlags = bits + 1 == 16 ? kAppleLosslessFormatFlag_16BitSourceData
      : kAppleLosslessFormatFlag_24BitSourceData
    coreAudioCookie = Data([0, 0, 0, 50, 0x64, 0x66, 0x4c, 0x61,
      0, 0, 0, 0, 0x80, 0, 0, 34] + data)
  }

  /// Bound allocation using the actual frame header, including a short final
  /// block. The complete compressed frame is still passed to the system decoder.
  func frameCount(packet: Data) -> UInt32? {
    guard packet.count >= 6 else { return nil }
    func byte(_ offset: Int) -> UInt8 { packet[packet.startIndex + offset] }
    guard byte(0) == 0xff, byte(1) & 0xfe == 0xf8, byte(3) & 1 == 0 else { return nil }
    let code = byte(2) >> 4
    let firstNumberByte = byte(4)
    let numberBytes: Int
    if firstNumberByte & 0x80 == 0 { numberBytes = 1 }
    else {
      numberBytes = (~firstNumberByte).leadingZeroBitCount
      guard (2...7).contains(numberBytes) else { return nil }
    }
    var offset = 4 + numberBytes
    guard offset < packet.count else { return nil }
    for index in 5..<offset {
      guard byte(index) & 0xc0 == 0x80 else { return nil }
    }
    let frames: UInt32
    switch code {
    case 1: frames = 192
    case 2...5: frames = 576 << UInt32(code - 2)
    case 6: frames = UInt32(byte(offset)) + 1; offset += 1
    case 7:
      guard offset + 1 < packet.count else { return nil }
      frames = (UInt32(byte(offset)) << 8 | UInt32(byte(offset + 1))) + 1
      offset += 2
    case 8...15: frames = 256 << UInt32(code - 8)
    default: return nil
    }
    guard offset < packet.count, frames <= maxBlockSize else { return nil }
    return frames
  }
}
