import CoreMedia
import Foundation
import YlFFmpegBridge

enum YlFELFailure {
  static func make(_ code: String = "decoder.dolby_vision_fel_invalid", _ detail: String) -> NativePlayerError {
    NativePlayerError(category: "decoderFailure", code: code,
      message: "The complete Dolby Vision enhancement layer could not be rendered.", diagnostic: detail)
  }
  static func metadata(_ dictionary: [String: Any]) throws -> YlFELMetadata {
    do { return try YlFELMetadata(dictionary: dictionary) }
    catch {
      throw NativePlayerError(category: "unsupported", code: "decoder.dolby_vision_fel_metadata_unsupported",
        message: "Complete rendering of this Dolby Vision enhancement metadata is unsupported.",
        diagnostic: error.localizedDescription)
    }
  }
}

/// Owns copied stream configuration, never a borrowed demux pointer. Every
/// decoder epoch clones this template with fresh RPU reference history.
final class YlFELConfiguration {
  let baseFormat: CMVideoFormatDescription
  let enhancementFormat: CMVideoFormatDescription
  private let template: YLFFELContextRef
  private let lock = NSLock()

  private init(template: YLFFELContextRef, unit: [String: Any]) throws {
    baseFormat = try Self.format(unit, key: "baseFormat")
    enhancementFormat = try Self.format(unit, key: "enhancementFormat")
    guard let metadata = unit["metadata"] as? [String: Any] else {
      throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "Missing FEL metadata")
    }
    _ = try YlFELFailure.metadata(metadata)
    self.template = template
  }

  static func format(_ unit: [String: Any], key: String) throws -> CMVideoFormatDescription {
    guard let value = unit[key], CFGetTypeID(value as CFTypeRef) == CMFormatDescriptionGetTypeID() else {
      throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "Missing FEL format")
    }
    return value as! CMVideoFormatDescription
  }

  func freshParser() throws -> YLFFELContextRef {
    lock.lock(); defer { lock.unlock() }
    var copy: YLFFELContextRef?
    let status = ylf_fel_clone(template, &copy)
    guard status == YLFResultOK, let copy else {
      throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "FEL clone result \(status)")
    }
    return copy
  }

  static func probe(context: YLFMediaContextRef, streamIndex: Int32, maxPacketBytes: Int,
                    checkCancellation: () throws -> Void = {},
                    reserveBytes: (Int) throws -> AnyObject? = { _ in nil },
                    rewind: () throws -> Void) throws -> YlFELConfiguration? {
    guard ylf_stream_dolby_vision_profile(context, streamIndex) == 7 else { return nil }
    try checkCancellation()
    var parser: YLFFELContextRef?
    let status = ylf_fel_create(context, streamIndex, &parser)
    guard status == YLFResultOK, let ownedParser = parser else {
      throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "FEL configuration result \(status)")
    }
    var transferred = false
    defer { if !transferred { ylf_fel_free(ownedParser) } }
    var consumed = false
    do {
      var remaining = 8 * 1024 * 1024
      for _ in 0..<64 {
        try checkCancellation()
        var packet: YLFPacketRef?
        let result = ylf_read_packet(context, &packet)
        consumed = true
        defer { ylf_packet_release(&packet) }
        guard result == YLFResultOK, let ownedPacket = packet else {
          throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "FEL opening probe result \(result)")
        }
        let size = ylf_packet_size(ownedPacket)
        guard size > 0, size <= maxPacketBytes, size <= remaining else {
          throw YlFELFailure.make("resource.network_buffer_limit", "FEL opening probe exceeded its byte budget")
        }
        remaining -= size
        guard ylf_packet_stream_index(ownedPacket) == streamIndex else { continue }
        let reservation = try reserveBytes(size * 4 + 128 * 1024)
        defer { withExtendedLifetime(reservation) {} }
        var raw: Unmanaged<CFDictionary>?
        let accessResult = ylf_fel_copy_access_unit(ownedParser, ownedPacket, &raw)
        guard accessResult == YLFResultOK, let raw else {
          throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "FEL access-unit result \(accessResult)")
        }
        let value = raw.takeRetainedValue() as NSDictionary
        guard let unit = value as? [String: Any] else {
          throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "Invalid FEL access unit")
        }
        // Rewind succeeds before any template is published to playback.
        try rewind()
        consumed = false
        try checkCancellation()
        let configuration = try YlFELConfiguration(template: ownedParser, unit: unit)
        transferred = true
        return configuration
      }
      throw YlFELFailure.make("decoder.dolby_vision_fel_invalid", "FEL opening probe found no video access unit")
    } catch {
      if consumed { try rewind() }
      throw error
    }
  }

  deinit { ylf_fel_free(template) }
}
