/// Immutable half-open programme windows. Source sample overlap is clipped at
/// the next Period start; gaps stay on the programme clock instead of collapsing.
struct YlDashProgramTimeline {
  struct Period {
    let start: YlDashProgramTime?
    let duration: YlDashProgramTime?
  }
  struct Window {
    let start: YlDashProgramTime
    let end: YlDashProgramTime
  }
  let windows: [Window]
  let duration: YlDashProgramTime

  init(periods: [Period]) throws {
    guard !periods.isEmpty, periods.count <= 64 else { throw YlDashProgramError.limitExceeded }
    let zero = try YlDashProgramTime(0)
    var resolved: [Window] = []
    for (index, period) in periods.enumerated() {
      let start = period.start ?? resolved.last?.end ?? zero
      guard start >= zero, resolved.last.map({ start > $0.start }) ?? true else { throw YlDashProgramError.invalidPeriod }
      let span: YlDashProgramTime
      if let declared = period.duration { span = declared }
      else if index + 1 < periods.count, let next = periods[index + 1].start { span = try next.subtracting(start) }
      else { throw YlDashProgramError.unresolvedPeriod }
      guard span > zero else { throw YlDashProgramError.invalidPeriod }
      resolved.append(Window(start: start, end: try start.adding(span)))
    }
    self.duration = resolved.last!.end
    self.windows = resolved.enumerated().map { index, window in
      Window(start: window.start, end: index + 1 < resolved.count ? min(window.end, resolved[index + 1].start) : window.end)
    }
  }

  func locate(time: YlDashProgramTime) -> Int? {
    windows.firstIndex { time >= $0.start && time < $0.end }
  }
  func end(of period: Int) throws -> YlDashProgramTime { try window(period).end }
  func map(sample: YlDashProgramTime, offset: YlDashProgramTime, period: Int) throws -> YlDashProgramTime {
    try window(period).start.adding(sample.subtracting(offset))
  }
  /// Inverse mapping keeps seeking independent of public millisecond rounding.
  func sourceTime(program: YlDashProgramTime, offset: YlDashProgramTime, period: Int) throws -> YlDashProgramTime {
    try program.subtracting(window(period).start).adding(offset)
  }
  private func window(_ index: Int) throws -> Window {
    guard windows.indices.contains(index) else { throw YlDashProgramError.invalidPeriod }
    return windows[index]
  }
}
