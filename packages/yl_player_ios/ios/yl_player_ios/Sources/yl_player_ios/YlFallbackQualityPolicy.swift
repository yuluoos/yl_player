import Foundation

struct YlFallbackQualityConstraint: Equatable {
  static let unconstrained = YlFallbackQualityConstraint(
    maxWidth: nil,
    maxHeight: nil,
    maxBitrate: nil
  )

  let maxWidth: Int?
  let maxHeight: Int?
  let maxBitrate: Int?

  init(validating map: [String: Any?]) throws {
    func positive(_ key: String) throws -> Int? {
      guard let raw = map[key] else { return nil }
      let number = raw as? NSNumber
      let isNativeInteger = !(raw is Bool)
        && number?.doubleValue.isFinite == true
        && number?.doubleValue.rounded(.towardZero) == number?.doubleValue
      guard isNativeInteger,
            let value = int64(raw),
            value > 0,
            value <= Int64(Int32.max) else {
        throw NativePlayerError(
          category: "source",
          code: "source.quality_constraint_invalid",
          message: "Quality constraint values must be positive native integers."
        )
      }
      return Int(value)
    }

    maxWidth = try positive("maxWidth")
    maxHeight = try positive("maxHeight")
    maxBitrate = try positive("maxBitrate")
  }

  private init(maxWidth: Int?, maxHeight: Int?, maxBitrate: Int?) {
    self.maxWidth = maxWidth
    self.maxHeight = maxHeight
    self.maxBitrate = maxBitrate
  }
}

struct YlFallbackVideoDescriptor: Equatable {
  let width: Int
  let height: Int
  let bitrate: Int?
}

enum YlFallbackQualityPolicy {
  static func validate(
    constraint: YlFallbackQualityConstraint,
    stream: YlFallbackVideoDescriptor
  ) throws {
    let exceedsSize = constraint.maxWidth.map { stream.width > $0 } ?? false
      || constraint.maxHeight.map { stream.height > $0 } ?? false
    let exceedsBitrate = constraint.maxBitrate.map { maximum in
      guard let bitrate = stream.bitrate else { return true }
      return bitrate > maximum
    } ?? false

    guard !exceedsSize, !exceedsBitrate else {
      throw NativePlayerError(
        category: "decoderUnsupported",
        code: "decoder.quality_constraint_unsupported",
        message: "The fixed fallback video stream exceeds the requested quality constraint."
      )
    }
  }
}
