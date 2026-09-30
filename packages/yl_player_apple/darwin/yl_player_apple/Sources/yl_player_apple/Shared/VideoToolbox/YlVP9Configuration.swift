import CoreMedia
import Foundation
import YlFFmpegBridge

func ylVP9UnsupportedError() -> NativePlayerError {
  .init(category: "decoderUnsupported", code: "decoder.video_vp9_unsupported",
    message: "VP9 currently requires fixed-size Profile 0, 8-bit SDR visible frames without superframes. Try another video track.")
}

enum YlVP9Configuration {
  private static let openingKey = "YLVP9OpeningConfiguration" as CFString
  static func packetGate(for format: CMVideoFormatDescription) -> YlVP9PacketGate? {
    guard let data = CMFormatDescriptionGetExtension(format, extensionKey: openingKey) as? Data,
          data.count == 12 else { return nil }
    let bytes = [UInt8](data)
    guard bytes[0] == 1, bytes[4] == 0, bytes[6] & 0xfe == 0x82,
          [1, 2, 6].contains(bytes[7]), bytes[7] == bytes[8], bytes[8] == bytes[9] else { return nil }
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    return YlVP9PacketGate(opening: .init(keyframe: true, width: Int(dimensions.width), height: Int(dimensions.height),
      colorSpace: bytes[7] == 1 ? 2 : bytes[7] == 6 ? 1 : 0, fullRange: bytes[6] & 1 != 0))
  }

  static func makeFormatDescription(context: YLFMediaContextRef, stream: YLFStreamInfo,
    maxPacketBytes: Int, checkCancellation: () throws -> Void,
    reserveBytes: (Int) throws -> AnyObject?, readFailure: (Int32) -> Error, rewind: () throws -> Void) throws -> CMVideoFormatDescription {
    var remaining = 8 * 1024 * 1024
    for _ in 0..<64 {
      try checkCancellation()
      var packet: YLFPacketRef?
      let result = ylf_read_packet(context, &packet)
      defer { ylf_packet_release(&packet) }
      guard result == YLFResultOK, let owned = packet else {
        try checkCancellation(); throw result == YLFResultEOF ? ylVP9UnsupportedError() : readFailure(result)
      }
      let count = ylf_packet_size(owned)
      guard count > 0, count <= maxPacketBytes, count <= remaining else { throw ylVP9UnsupportedError() }
      remaining -= count
      let reservation = try reserveBytes(count)
      defer { withExtendedLifetime(reservation) {} }
      guard ylf_packet_stream_index(owned) == stream.index else { continue }
      guard let bytes = ylf_packet_data(owned),
        let header = YlVP9FrameHeader.parse(.init(start: bytes, count: count)), header.keyframe,
        header.width == stream.width, header.height == stream.height else { throw ylVP9UnsupportedError() }
      let format = try YlVideoToolboxDecoder.makeFormatDescription(context: context,
        streamIndex: stream.index, configuration: header.configuration)
      // Preserve bitstream constraints separately from container color overrides.
      // This also covers a seek before any packet reaches the first decoder.
      var extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
      extensions[openingKey as String] = Data(header.configuration)
      var guarded: CMVideoFormatDescription?
      guard CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_VP9,
        width: stream.width, height: stream.height, extensions: extensions as CFDictionary,
        formatDescriptionOut: &guarded) == noErr, let guarded else { throw ylVP9UnsupportedError() }
      try checkCancellation(); try rewind(); try checkCancellation()
      return guarded
    }
    throw ylVP9UnsupportedError()
  }
}
