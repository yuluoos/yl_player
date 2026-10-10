import Foundation

struct YlAudioClockSample: Equatable {
  let generation: UInt64
  let positionUs: Int64
  let hostTimeUs: Int64
  let lowerBoundUs: Int64
  let upperBoundUs: Int64
  let rate: Double
  func position(atHostTimeUs now: Int64) -> Int64? {
    guard rate.isFinite, rate >= 0.25, rate <= 4, hostTimeUs >= 0,
          lowerBoundUs >= 0, upperBoundUs >= lowerBoundUs,
          positionUs >= lowerBoundUs, positionUs <= upperBoundUs else { return nil }
    let value = Double(positionUs) + (Double(now) - Double(hostTimeUs)) * rate
    guard value.isFinite else { return nil }
    if value <= Double(lowerBoundUs) { return lowerBoundUs }
    if value >= Double(upperBoundUs) { return upperBoundUs }
    return Int64(value.rounded(.towardZero))
  }
}

enum YlAudioClockObservation: Equatable {
  case running(YlAudioClockSample)
  case silence(YlAudioClockSample)
  case waiting
  case paused(positionUs: Int64)
  case ended(positionUs: Int64, hostTimeUs: Int64)
  case invalid
}
