import Foundation
var results: [[String: Any]] = []
func check(_ name: String, _ body: () throws -> Bool) {
  do { results.append(["name": name, "passed": try body()]) }
  catch { results.append(["name": name, "passed": false, "error": String(describing: error)]) }
}
func time(_ n: Int64, _ d: Int64 = 1) throws -> YlDashProgramTime { try .init(n, d) }
let clip = try YlDashProgramTimeline.Window(start: time(0), end: time(7,2))
check("video before end retains clipped duration") {
  let value = try YlDashSampleWindow.intersection(pts: time(83,24), duration: time(1,24), window: clip)
  return try value?.start == time(83,24) && value?.end == time(7,2)
}
check("video at exclusive end is suppressed") {
  try YlDashSampleWindow.intersection(pts: time(7,2), duration: time(1,24), window: clip) == nil
}
check("negative AAC priming produces only nonnegative PCM") {
  try YlDashSampleWindow.pcmFrames(pts: time(-1024,48000), sampleRate: 48000, count: 2048, window: clip) == .init(skip: 1024, count: 1024)
}
check("PCM cuts final packet at 3.5 seconds exactly") {
  try YlDashSampleWindow.pcmFrames(pts: time(167936,48000), sampleRate: 48000, count: 1024, window: clip) == .init(skip: 0, count: 64)
}
check("fractional sample boundary never leaks a frame beyond end") {
  let window = try YlDashProgramTimeline.Window(start: time(0), end: time(1,7))
  return try YlDashSampleWindow.pcmFrames(pts: time(0), sampleRate: 48000, count: 8192, window: window) == .init(skip: 0, count: 6857)
}
check("fractional start excludes frame beginning before seek") {
  let window = try YlDashProgramTimeline.Window(start: time(1,7), end: time(1))
  return try YlDashSampleWindow.pcmFrames(pts: time(0), sampleRate: 48000, count: 8192, window: window) == .init(skip: 6858, count: 1334)
}
check("entire pre-window PCM is dropped") {
  let window = try YlDashProgramTimeline.Window(start: time(3), end: time(4))
  return try YlDashSampleWindow.pcmFrames(pts: time(1), sampleRate: 48000, count: 1024, window: window).count == 0
}
check("overlap only clips output before new period begins") {
  let program = try YlDashProgramTimeline(periods: [.init(start: time(0), duration: time(4)), .init(start: time(3), duration: time(4))])
  return try YlDashSampleWindow.pcmFrames(pts: time(143360,48000), sampleRate: 48000, count: 1024, window: program.windows[0]) == .init(skip: 0, count: 640)
}
print(String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), as: UTF8.self))
