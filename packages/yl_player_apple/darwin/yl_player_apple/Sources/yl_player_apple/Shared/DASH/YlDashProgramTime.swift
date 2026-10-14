/// Safe private failures, translated to public errors at the program admission boundary.
enum YlDashProgramError: Error { case invalidTime, overflow, unresolvedPeriod, invalidPeriod, limitExceeded }

/// Reduced signed seconds. MPD, sample and programme boundaries remain rational;
/// only public duration/renderer boundaries explicitly select a rounding rule.
struct YlDashProgramTime: Equatable, Comparable {
  enum Rounding { case exact, floor, ceil }
  let numerator: Int64
  let denominator: Int64

  init(_ numerator: Int64, _ denominator: Int64 = 1) throws {
    guard denominator > 0 else { throw YlDashProgramError.invalidTime }
    let divisor = Int64(Self.gcd(numerator.magnitude, UInt64(denominator)))
    self.numerator = numerator / divisor
    self.denominator = denominator / divisor
  }

  func adding(_ other: Self) throws -> Self { try combining(other, subtract: false) }
  func subtracting(_ other: Self) throws -> Self { try combining(other, subtract: true) }

  private func combining(_ other: Self, subtract: Bool) throws -> Self {
    let common = Int64(Self.gcd(UInt64(denominator), UInt64(other.denominator)))
    let left = numerator.multipliedFullWidth(by: other.denominator / common)
    let right = other.numerator.multipliedFullWidth(by: denominator / common)
    let low = subtract ? left.low.subtractingReportingOverflow(right.low) : left.low.addingReportingOverflow(right.low)
    // Two signed 64×positive63 products fit signed128, as does their sum/difference.
    let high = subtract ? left.high &- right.high &- (low.overflow ? 1 : 0)
      : left.high &+ right.high &+ (low.overflow ? 1 : 0)
    let value = Self.magnitude(high: high, low: low.partialValue)
    let remainder = Self.divide(value, by: UInt64(common)).remainder
    let reduction = Self.gcd(remainder, UInt64(common))
    let quotient = Self.divide(value, by: reduction)
    let n = try Self.signed(quotient.high, quotient.low, negative: high < 0)
    let d = (denominator / common).multipliedReportingOverflow(by: other.denominator / Int64(reduction))
    guard !d.overflow else { throw YlDashProgramError.overflow }
    return try Self(n, d.partialValue)
  }

  func converted(to scale: Int64, rounding: Rounding) throws -> Int64 {
    guard scale > 0 else { throw YlDashProgramError.invalidTime }
    let wide = numerator.multipliedFullWidth(by: scale)
    let quotient = Self.divide(Self.magnitude(high: wide.high, low: wide.low), by: UInt64(denominator))
    var value = try Self.signed(quotient.high, quotient.low, negative: wide.high < 0)
    if quotient.remainder != 0 {
      switch rounding {
      case .exact: throw YlDashProgramError.invalidTime
      case .floor where numerator < 0:
        let next = value.subtractingReportingOverflow(1)
        guard !next.overflow else { throw YlDashProgramError.overflow }; value = next.partialValue
      case .ceil where numerator > 0:
        let next = value.addingReportingOverflow(1)
        guard !next.overflow else { throw YlDashProgramError.overflow }; value = next.partialValue
      default: break
      }
    }
    return value
  }

  static func < (lhs: Self, rhs: Self) -> Bool {
    let left = lhs.numerator.multipliedFullWidth(by: rhs.denominator)
    let right = rhs.numerator.multipliedFullWidth(by: lhs.denominator)
    return left.high == right.high ? left.low < right.low : left.high < right.high
  }

  private static func gcd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    var a = lhs, b = rhs
    while b != 0 { let remainder = a % b; a = b; b = remainder }
    return a
  }
  private static func magnitude(high: Int64, low: UInt64) -> (high: UInt64, low: UInt64) {
    guard high < 0 else { return (UInt64(high), low) }
    let low = (~low).addingReportingOverflow(1)
    return (~UInt64(bitPattern: high) &+ (low.overflow ? 1 : 0), low.partialValue)
  }
  private static func divide(_ value: (high: UInt64, low: UInt64), by divisor: UInt64) -> (high: UInt64, low: UInt64, remainder: UInt64) {
    let first = value.high / divisor
    let second = divisor.dividingFullWidth((high: value.high % divisor, low: value.low))
    return (first, second.quotient, second.remainder)
  }
  private static func signed(_ high: UInt64, _ low: UInt64, negative: Bool) throws -> Int64 {
    guard high == 0, low <= UInt64(Int64.max) + (negative ? 1 : 0) else { throw YlDashProgramError.overflow }
    if negative && low == UInt64(Int64.max) + 1 { return Int64.min }
    return negative ? -Int64(low) : Int64(low)
  }
}
