import Foundation

struct YlBoundedBufferPlan: Equatable {
  let minDurationUs: Int64
  let maxDurationUs: Int64
  let maxBytes: Int
  // Scheduling watermarks leave room for simultaneous packet copies, conversion,
  // transport/inspection and a decoded frame. They are not separate ledgers.
  static let safetyBytes = 2 * 1024 * 1024
  init(minDurationMs: Int64, maxDurationMs: Int64, maxBytes: Int) throws {
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
  func validate(width: Int, height: Int) throws {
    let pixels = width.multipliedReportingOverflow(by: height)
    let frame = pixels.partialValue.multipliedReportingOverflow(by: 4)
    guard maxDurationUs > 0, width > 0, height > 0, !pixels.overflow, !frame.overflow,
          frame.partialValue <= (maxBytes - Self.safetyBytes) / 2 else { throw YlManagedBufferLedger.unsupported() }
  }
  var networkWatermark: Int { min(1024 * 1024, maxBytes / 8) }
  func admits(durationUs: Int64, nextDurationUs: Int64) -> Bool {
    let next = max(0, nextDurationUs)
    return durationUs >= 0 && durationUs <= maxDurationUs && next <= maxDurationUs - durationUs
  }
  func ready(durationUs: Int64, eof: Bool, producerLimited: Bool) -> Bool {
    durationUs >= minDurationUs || ((eof || producerLimited) && durationUs > 0)
  }
}
