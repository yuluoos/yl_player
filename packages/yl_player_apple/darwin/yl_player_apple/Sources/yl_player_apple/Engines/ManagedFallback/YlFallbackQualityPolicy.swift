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

  init(validating constraints: YlAppleVideoConstraints) throws {
    for value in [constraints.maxWidth, constraints.maxHeight, constraints.maxBitrate].compactMap({ $0 }) {
      guard value > 0, value <= Int(Int32.max) else {
        throw NativePlayerError(category: "source", code: "source.quality_constraint_invalid",
          message: "Quality constraint values must be positive native integers.")
      }
    }
    maxWidth = constraints.maxWidth
    maxHeight = constraints.maxHeight
    maxBitrate = constraints.maxBitrate
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
