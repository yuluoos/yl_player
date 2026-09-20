import CoreMedia
import Foundation
import YlFFmpegBridge

/// Opening-only probe for seekable inputs with a header-only hvcC. A successful
/// probe must rewind before the context can be handed to the playback pipeline.
enum YlHEVCInBandConfiguration {
  static func makeFormatDescription(
    context: YLFMediaContextRef,
    streamIndex: Int32,
    maxPacketBytes: Int,
    checkCancellation: () throws -> Void = {},
    reserveBytes: (Int) throws -> AnyObject? = { _ in nil },
    readFailure: (Int32) -> Error = { result in
      NativePlayerError(category: "container", code: "container.mkv_malformed",
        message: "The video configuration probe could not read media packets.",
        diagnostic: "YlFFmpegBridge result \(result)")
    },
    rewind: () throws -> Void
  ) throws -> CMVideoFormatDescription? {
    var stream = YLFStreamInfo()
    guard ylf_copy_stream_info(context, streamIndex, &stream) == YLFResultOK,
          stream.codec == Int32(YLFCodecHEVC),
          ylf_stream_codec_config_size(context, streamIndex) == 23 else { return nil }
    var header = [UInt8](repeating: 0, count: 23)
    guard ylf_copy_stream_codec_config(context, streamIndex, &header, header.count) == YLFResultOK,
          header[0] == 1, header[22] == 0 else { return nil }
    try checkCancellation()
    // At most three UInt16-sized parameter sets plus the rebuilt configuration
    // and its CoreMedia copy. Never retain a compressed frame across iterations.
    let configurationReservation = try reserveBytes(3 * (3 * Int(UInt16.max) + 38))
    defer { withExtendedLifetime(configurationReservation) {} }
    let nalLengthSize = Int(header[21] & 3) + 1
    var parameterSets: [UInt8: [UInt8]] = [:]
    var remainingBytes = 8 * 1024 * 1024
    for _ in 0..<32 {
      try checkCancellation()
      var packet: YLFPacketRef?
      let result = ylf_read_packet(context, &packet)
      defer { ylf_packet_release(&packet) }
      if result == YLFResultEOF { return nil }
      guard result == YLFResultOK, let ownedPacket = packet else {
        try checkCancellation()
        throw readFailure(result)
      }
      let count = ylf_packet_size(ownedPacket)
      guard count > 0, count <= maxPacketBytes, count <= remainingBytes else { return nil }
      remainingBytes -= count
      let packetReservation = try reserveBytes(count)
      defer { withExtendedLifetime(packetReservation) {} }
      guard ylf_packet_stream_index(ownedPacket) == streamIndex else { continue }
      guard let bytes = ylf_packet_data(ownedPacket),
            let found = parameterSetsInPacket(
              UnsafeBufferPointer(start: bytes, count: count), nalLengthSize: nalLengthSize
            ) else { return nil }
      for (type, bytes) in found { parameterSets[type] = bytes }
      guard [UInt8(32), 33, 34].allSatisfy({ parameterSets[$0] != nil }) else { continue }
      header[22] = 3
      for type: UInt8 in [32, 33, 34] {
        guard let bytes = parameterSets[type] else { return nil }
        header += [0x80 | type, 0, 1, UInt8(bytes.count >> 8), UInt8(bytes.count & 255)]
        header += bytes
      }
      let format = try YlVideoToolboxDecoder.makeFormatDescription(
        context: context, streamIndex: streamIndex, configuration: header)
      try checkCancellation()
      try rewind()
      try checkCancellation()
      NSLog("%@", "[YLPlayer][VideoToolbox] event=inBandVideoConfiguration codec=hevc"
        + " streamIndex=\(streamIndex) configBytes=\(header.count)")
      return format
    }
    return nil
  }

  private static func parameterSetsInPacket(
    _ packet: UnsafeBufferPointer<UInt8>, nalLengthSize: Int
  ) -> [UInt8: [UInt8]]? {
    var result: [UInt8: [UInt8]] = [:]
    var offset = 0
    while offset < packet.count {
      guard packet.count - offset >= nalLengthSize else { return nil }
      var length = 0
      for _ in 0..<nalLengthSize { length = length * 256 + Int(packet[offset]); offset += 1 }
      guard length >= 2, length <= packet.count - offset else { return nil }
      let type = (packet[offset] >> 1) & 63
      if type == 32 || type == 33 || type == 34 {
        guard length <= Int(UInt16.max) else { return nil }
        result[type] = Array(packet[offset..<(offset + length)])
      }
      offset += length
    }
    return result
  }
}
