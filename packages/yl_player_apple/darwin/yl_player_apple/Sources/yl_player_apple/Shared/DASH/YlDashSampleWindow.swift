/// Exact source-to-program sample admission. The decoder still receives preroll;
/// only presentation is clipped. The end is exclusive, including overlap cuts.
enum YlDashSampleWindow {
  typealias Time = YlDashProgramTime
  struct Frames: Equatable { let skip: Int; let count: Int }
  static func intersection(pts: Time, duration: Time, window: YlDashProgramTimeline.Window) throws -> YlDashProgramTimeline.Window? {
    guard duration.numerator > 0, window.end >= window.start else { throw YlDashProgramError.invalidTime }
    let start = max(pts, window.start), end = min(try pts.adding(duration), window.end)
    return start < end ? .init(start: start, end: end) : nil
  }
  static func pcmFrames(pts: Time, sampleRate: Int64, count: Int, window: YlDashProgramTimeline.Window) throws -> Frames {
    guard sampleRate > 0, sampleRate <= 768_000, count >= 0, count <= 1_048_576,
          window.end >= window.start else { throw YlDashProgramError.invalidTime }
    let first = try window.start.subtracting(pts).converted(to: sampleRate, rounding: .ceil)
    let last = try window.end.subtracting(pts).converted(to: sampleRate, rounding: .floor)
    let skip = min(Int64(count), max(0, first))
    let end = min(Int64(count), max(skip, last))
    return .init(skip: Int(skip), count: Int(end - skip))
  }
}
