import yl_player_media_core
import Foundation

struct YlDashSidxReference: Equatable {
  let offset: UInt64
  let length: UInt64
  let durationTicks: UInt64
  let startsWithSAP: Bool
  let sapType: UInt8
  let sapDeltaTicks: UInt32
}
struct YlDashSidxIndex {
  let referenceID: UInt32
  let timescale: UInt32
  let earliestPresentationTimeTicks: UInt64
  let references: [YlDashSidxReference]
}

/// Private, payload-free reasons. The loader may map these to existing public
/// codes; parsing never keeps bytes, addresses or an underlying error string.
enum YlDashSidxError: Error, Equatable {
  case invalidIndex, unsupportedIndex, limitExceeded
  var nativeError: NativePlayerError {
    switch self {
    case .invalidIndex:
      return NativePlayerError(category: "container", code: "container.unsupported",
        message: "The DASH segment index is invalid. Ask the provider for a valid segment index.")
    case .unsupportedIndex:
      return NativePlayerError(category: "container", code: "container.unsupported",
        message: "This DASH segment index format is unsupported. Choose a compatible source.")
    case .limitExceeded:
      return NativePlayerError(category: "resource", code: "resource.exhausted",
        message: "The DASH segment index exceeds the permitted byte or reference budget.")
    }
  }
}

/// Pure parser for exactly one explicit-size sidx box. `boxEndOffset` is the
/// absolute, exclusive end in the original resource (not an offset in `data`).
/// Raw SAP metadata is retained; it does not itself authorize independent seeks.
enum YlDashSidx {
  static let maxIndexBytes = 1_048_576

  static func parse(_ data: Data, boxEndOffset: UInt64,
    maxReferences: Int) throws -> YlDashSidxIndex {
    guard data.count <= maxIndexBytes, maxReferences > 0 else { throw YlDashSidxError.limitExceeded }
    guard boxEndOffset >= UInt64(data.count) else { throw YlDashSidxError.invalidIndex }
    var reader = Reader(bytes: Array(data))
    let shortSize = try reader.read(4)
    guard try reader.read(4) == 0x73696478 else { throw YlDashSidxError.invalidIndex }
    guard shortSize != 0 else { throw YlDashSidxError.unsupportedIndex }
    let size = try shortSize == 1 ? reader.read(8) : shortSize
    guard size == UInt64(data.count) else { throw YlDashSidxError.invalidIndex }
    let fullBox = try reader.read(4)
    let version = fullBox >> 24
    guard version <= 1, fullBox & 0xFFFFFF == 0 else { throw YlDashSidxError.unsupportedIndex }
    let referenceID = UInt32(try reader.read(4))
    let timescale = UInt32(try reader.read(4))
    guard timescale > 0 else { throw YlDashSidxError.invalidIndex }
    let earliest = try reader.read(version == 0 ? 4 : 8)
    let firstOffset = try reader.read(version == 0 ? 4 : 8)
    guard try reader.read(2) == 0 else { throw YlDashSidxError.invalidIndex }
    let count = Int(try reader.read(2))
    guard count > 0 else { throw YlDashSidxError.invalidIndex }
    guard count <= maxReferences else { throw YlDashSidxError.limitExceeded }
    // count is UInt16-sized; multiplication is bounded. Reject truncation/extra
    // boxes before allocating or iterating the reference table.
    guard reader.remaining == count * 12 else { throw YlDashSidxError.invalidIndex }
    var offset = try add(boxEndOffset, firstOffset)
    var time = earliest
    var references: [YlDashSidxReference] = []
    references.reserveCapacity(count)
    for _ in 0..<count {
      let reference = try reader.read(4)
      guard reference & 0x80000000 == 0 else { throw YlDashSidxError.unsupportedIndex }
      let length = reference & 0x7FFFFFFF
      let duration = try reader.read(4)
      let sap = try reader.read(4)
      guard length > 0, duration > 0 else { throw YlDashSidxError.invalidIndex }
      let end = try add(offset, length)
      time = try add(time, duration)
      references.append(YlDashSidxReference(offset: offset, length: length,
        durationTicks: duration, startsWithSAP: sap & 0x80000000 != 0,
        sapType: UInt8((sap >> 28) & 7), sapDeltaTicks: UInt32(sap & 0x0FFFFFFF)))
      offset = end
    }
    return YlDashSidxIndex(referenceID: referenceID, timescale: timescale,
      earliestPresentationTimeTicks: earliest, references: references)
  }

  private static func add(_ left: UInt64, _ right: UInt64) throws -> UInt64 {
    let result = left.addingReportingOverflow(right)
    guard !result.overflow else { throw YlDashSidxError.invalidIndex }
    return result.partialValue
  }
  private struct Reader {
    let bytes: [UInt8]
    var cursor = 0
    var remaining: Int { bytes.count - cursor }
    mutating func read(_ count: Int) throws -> UInt64 {
      guard remaining >= count else { throw YlDashSidxError.invalidIndex }
      var value: UInt64 = 0
      for _ in 0..<count {
        value = (value << 8) | UInt64(bytes[cursor])
        cursor += 1
      }
      return value
    }
  }
}

/// Per-manifest identity; stripping is part of the key, so a cross-origin branch
/// can never reuse a credential-bearing fetch of the same URL.
struct YlDashIndexRequest: Hashable {
  let url: URL
  let start: Int64
  let length: Int
  let credentialsStripped: Bool
}
struct YlDashResolvedIndex {
  let index: YlDashSidxIndex
  let effectiveURL: URL
  let credentialsStripped: Bool
  let resourceLength: Int64
}
