import Foundation
var results: [[String: Any]] = []
func check(_ name: String, _ body: () throws -> Bool) {
  do { results.append(["name": name, "passed": try body()]) }
  catch { results.append(["name": name, "passed": false, "error": String(describing: error)]) }
}
func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
func t(_ n: Int64, _ d: Int64 = 1) throws -> YlDashProgramTime { try YlDashProgramTime(n, d) }
check("reduced identity") { try t(2, 6) == t(1, 3) }
check("exact sum") { try t(1, 3).adding(t(1, 6)) == t(1, 2) }
check("negative priming") { try t(-1024, 48000).adding(t(1)) == t(367, 375) }
check("cancellation without overflow") { try t(Int64.max, 2).subtracting(t(Int64.max, 2)) == t(0) }
check("large rescale reduced before product") { try t(8_000_000_000_000_000, 1_000_000_000_000_000).converted(to: 1_000_000, rounding: .exact) == 8_000_000 }
check("positive floor") { try t(1, 3).converted(to: 1_000_000, rounding: .floor) == 333333 }
check("positive ceiling") { try t(1, 3).converted(to: 1_000_000, rounding: .ceil) == 333334 }
check("negative floor") { try t(-1, 3).converted(to: 1_000_000, rounding: .floor) == -333334 }
check("negative ceiling") { try t(-1, 3).converted(to: 1_000_000, rounding: .ceil) == -333333 }
check("exact conversion rejects fraction") { rejects { _ = try t(1, 3).converted(to: 1_000_000, rounding: .exact) } }
check("invalid denominator rejected") { rejects { _ = try t(1, 0) } && rejects { _ = try t(1, -1) } }
check("true overflow rejected") { rejects { _ = try t(Int64.max).adding(t(1)) } }
check("comparison avoids cross product overflow") { try t(Int64.max, Int64.max - 1) > t(Int64.max - 1, Int64.max) }
check("independent audio/video origins") {
  let timeline = try YlDashProgramTimeline(periods: [.init(start: t(0), duration: t(4))])
  return try timeline.map(sample: t(21, 2), offset: t(10), period: 0) == t(1, 2)
    && timeline.map(sample: t(41, 2), offset: t(20), period: 0) == t(1, 2)
}
check("gap preserves programme time") {
  let timeline = try YlDashProgramTimeline(periods: [.init(start: t(0), duration: t(4)), .init(start: t(5), duration: t(4))])
  return try timeline.locate(time: t(9, 2)) == nil && timeline.locate(time: t(5)) == 1 && timeline.duration == t(9)
}
check("overlap later Period owns boundary") {
  let timeline = try YlDashProgramTimeline(periods: [.init(start: t(0), duration: t(4)), .init(start: t(3), duration: t(4))])
  return try timeline.locate(time: t(3)) == 1 && timeline.end(of: 0) == t(3) && timeline.duration == t(7)
}
check("half open final endpoint") {
  let timeline = try YlDashProgramTimeline(periods: [.init(start: t(0), duration: t(1, 3))])
  return try timeline.locate(time: t(1, 3)) == nil && timeline.locate(time: t(1, 4)) == 0
}
check("unknown boundary not guessed") { rejects { _ = try YlDashProgramTimeline(periods: [.init(start: t(0), duration: nil), .init(start: nil, duration: t(4))]) } }
check("next explicit start resolves unknown duration") {
  let timeline = try YlDashProgramTimeline(periods: [.init(start: t(0), duration: nil), .init(start: t(4), duration: t(4))])
  return try timeline.end(of: 0) == t(4) && timeline.duration == t(8)
}
check("negative and reversed Periods rejected") {
  rejects { _ = try YlDashProgramTimeline(periods: [.init(start: t(-1), duration: t(4))]) }
    && rejects { _ = try YlDashProgramTimeline(periods: [.init(start: t(1), duration: t(4)), .init(start: t(0), duration: t(4))]) }
}
check("repeated mapping never rounds internal clock") {
  let timeline = try YlDashProgramTimeline(periods: [.init(start: t(1, 3), duration: t(2))])
  for _ in 0..<10000 {
    let program = try timeline.map(sample: t(21, 2), offset: t(10), period: 0)
    if try program != t(5, 6) { return false }
  }
  return true
}
check("inverse mapping of programme seek") {
  let timeline = try YlDashProgramTimeline(periods: [.init(start: t(1, 3), duration: t(2))])
  return try timeline.sourceTime(program: t(5, 6), offset: t(10), period: 0) == t(21, 2)
}
check("Period count is bounded") {
  rejects { _ = try YlDashProgramTimeline(periods: []) } && rejects {
    _ = try YlDashProgramTimeline(periods: (0..<65).map { _ in .init(start: nil, duration: try t(1)) })
  }
}
check("invalid Period index is rejected") {
  let timeline = try YlDashProgramTimeline(periods: [.init(start: t(0), duration: t(1))])
  return rejects { _ = try timeline.end(of: -1) } && rejects { _ = try timeline.map(sample: t(0), offset: t(0), period: 1) }
}
let input = FileHandle.standardInput.readDataToEndOfFile()
if !input.isEmpty {
  let rows = try JSONSerialization.jsonObject(with: input) as! [[String: Any]]
  for (index, row) in rows.enumerated() {
    check("independent Fraction oracle \(index)") {
      let a = try t(Int64(row["a"] as! String)!, Int64(row["d"] as! String)!)
      let b = try t(Int64(row["b"] as! String)!, Int64(row["e"] as! String)!)
      let op = row["op"] as! String
      if op == "less" { return (a < b) == (row["expected"] as! Bool) }
      let result = { try op == "add" ? a.adding(b) : a.subtracting(b) }
      guard let n = row["n"] as? String, let d = row["q"] as? String else { return rejects { _ = try result() } }
      return try result() == t(Int64(n)!, Int64(d)!)
    }
  }
}
print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), encoding: .utf8)!)
