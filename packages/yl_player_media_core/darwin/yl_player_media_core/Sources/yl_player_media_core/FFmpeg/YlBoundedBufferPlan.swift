import Foundation

public struct YlBoundedBufferPlan: Equatable {
  public let minDurationUs: Int64
  public let maxDurationUs: Int64
  public let maxBytes: Int
  // Scheduling watermarks leave room for simultaneous packet copies, conversion,
  // transport/inspection and a decoded frame. They are not separate ledgers.
  public static let safetyBytes = 2 * 1024 * 1024
  public init(minDurationMs: Int64, maxDurationMs: Int64, maxBytes: Int) throws {
    let low = minDurationMs.multipliedReportingOverflow(by: 1000)
    let high = maxDurationMs.multipliedReportingOverflow(by: 1000)
    guard minDurationMs >= 0, maxDurationMs >= minDurationMs,
          !low.overflow, !high.overflow, maxBytes > Self.safetyBytes else {
      throw YlManagedBufferLedger.unsupported()
    }
    minDurationUs = low.partialValue; maxDurationUs = high.partialValue; self.maxBytes = maxBytes
  }
  // A presented frame stays charged while its replacement is admitted. Two
  // maximum BGRA frames plus stage safety is the minimum progressing working set.
  public func validate(width: Int, height: Int) throws {
    let pixels = width.multipliedReportingOverflow(by: height)
    let frame = pixels.partialValue.multipliedReportingOverflow(by: 4)
    guard maxDurationUs > 0, width > 0, height > 0, !pixels.overflow, !frame.overflow,
          frame.partialValue <= (maxBytes - Self.safetyBytes) / 2 else { throw YlManagedBufferLedger.unsupported() }
  }
  public var networkWatermark: Int { min(1024 * 1024, maxBytes / 8) }
  public func admits(durationUs: Int64, nextDurationUs: Int64) -> Bool {
    let next = max(0, nextDurationUs)
    return durationUs >= 0 && durationUs <= maxDurationUs && next <= maxDurationUs - durationUs
  }
  public func ready(durationUs: Int64, eof: Bool, producerLimited: Bool) -> Bool {
    durationUs >= minDurationUs || ((eof || producerLimited) && durationUs > 0)
  }
}
