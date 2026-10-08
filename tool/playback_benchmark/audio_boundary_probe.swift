// Tool-only silent graph. Main thread owns the model; callback threads only journal.
import AVFAudio
import Foundation
import Darwin

func rawUs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000 }
typealias Model = AudioBoundaryPrototype<AVAudioPCMBuffer>
final class Journal {
  private let lock = NSLock()
  private var values: [(Model.Ticket, Bool, UInt64)] = []
  func record(_ ticket: Model.Ticket, _ boundary: Bool) {
    let time = rawUs(); lock.lock(); defer { lock.unlock() }
    values.append((ticket, boundary, time))
  }
  func snapshot() -> [(Model.Ticket, Bool, UInt64)] {
    lock.lock(); defer { lock.unlock() }; return values
  }
}
final class WeakPCM { weak var value: AVAudioPCMBuffer?; init(_ v: AVAudioPCMBuffer) { value = v } }
guard CommandLine.arguments.count == 2,
      ["single", "pausedEOF", "grouped", "reference"].contains(CommandLine.arguments[1]) else { exit(2) }
let scenario = CommandLine.arguments[1]
let target = scenario == "single" ? 1 : scenario == "pausedEOF" ? 3 : 200
let groupSize = scenario == "reference" ? 1 : 8
let model = Model(groupSize: groupSize, maxCount: 24, maxBytes: 24*8192, maxDurationUs: 24*21333)
let journal = Journal()
let completions = YlAudioCompletionGroup()
let engine = AVAudioEngine(); let player = AVAudioPlayerNode(); let pitch = AVAudioUnitTimePitch()
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
engine.attach(player); engine.attach(pitch)
pitch.pitch = 0; pitch.overlap = 8; pitch.rate = 1; pitch.bypass = true
engine.connect(player, to: pitch, format: format); engine.connect(pitch, to: engine.mainMixerNode, format: format)
engine.prepare()
var pcmRefs: [WeakPCM] = []
var accepted = 0; var eventIndex = 0
var submissions: [[String: Any]] = []
var samples: [[String: Any]] = []
var actions: [[String: Any]] = []
func checkpoint(_ phase: String) {
  let events: [[String: Any]] = journal.snapshot().map {
    ["ordinal": $0.0.ordinal, "generation": $0.0.generation, "boundary": $0.1, "rawUs": $0.2]
  }
  let row: [String: Any] = ["phase": phase, "scenario": scenario,
    "pid": ProcessInfo.processInfo.processIdentifier, "rawUs": rawUs(), "target": target,
    "accepted": accepted, "groupSize": groupSize, "pending": model.pendingCount,
    "pendingBytes": model.pendingBytes, "pendingDurationUs": model.pendingDurationUs,
    "peakCount": model.peakCount, "drained": model.drained,
    "alivePCM": pcmRefs.filter { $0.value != nil }.count,
    "submissions": submissions, "events": events, "samples": samples, "actions": actions]
  FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) + Data([10]))
  guard readLine() == "continue" else { exit(3) }
}
func pump() {
  while accepted < target {
    let status: Model.Admission = autoreleasepool {
      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
      pcm.frameLength = 1024
      for b in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
        if let ptr = b.mData { memset(ptr, 0, Int(b.mDataByteSize)) }
      }
      let result = model.enqueue(pcm, bytes: 8192, durationUs: 21333)
      if result == .accepted { pcmRefs.append(WeakPCM(pcm)); accepted += 1 }
      return result
    }
    if status == .backpressure { break }
    precondition(status == .accepted)
  }
  if accepted == target && !model.inputFinished {
    model.finishInput(); actions.append(["name": "EOF", "rawUs": rawUs(), "playing": player.isPlaying])
  }
  autoreleasepool {
    for submission in model.takeSubmissions() {
      let ticket = submission.ticket; let boundary = submission.isBoundary
      submissions.append(["ordinal": ticket.ordinal, "boundary": boundary, "frames": submission.payload.frameLength,
        "rawUs": rawUs()])
      // Clear delivered work using the production helper; system callback shells
      // may still survive until stop. Do not retain a PCM in this metadata closure.
      let done = completions.makeCompletion { journal.record(ticket, boundary) }
      player.scheduleBuffer(submission.payload, completionCallbackType: boundary ? .dataPlayedBack : .dataRendered) { _ in done() }
    }
  }
}
checkpoint("configured")
try engine.start()
let startedUs = rawUs()
// Explicitly establish a paused node before delivering EOF in this arm.
if scenario == "pausedEOF" { player.play(); player.pause(); actions.append(["name":"pause", "rawUs":rawUs()]) }
pump()
var playing = false
repeat {
  if !playing && (scenario != "pausedEOF" || rawUs()-startedUs >= 300_000) {
    player.play(); playing = true; actions.append(["name":"play", "rawUs":rawUs()])
  }
  let events = journal.snapshot()
  for event in events.dropFirst(eventIndex) {
    if event.1 { model.playedBack(event.0) } else { model.resourcesReleased(event.0) }
  }
  eventIndex = events.count
  pump()
  let time = player.lastRenderTime.flatMap { player.playerTime(forNodeTime: $0) }
  samples.append(["rawUs":rawUs(), "pending":model.pendingCount, "bytes":model.pendingBytes,
    "durationUs":model.pendingDurationUs, "drained":model.drained, "playing":player.isPlaying,
    "sampleTime":time.map { $0.sampleTime as Any } ?? NSNull()])
  RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
} while rawUs()-startedUs < (target == 200 ? 7_000_000 : 1_500_000)
checkpoint("observed")
player.stop(); player.reset(); engine.stop()
model.resetAfterOutputStop()
for node in [player, pitch] { engine.disconnectNodeOutput(node); engine.detach(node) }
checkpoint("disposed")
