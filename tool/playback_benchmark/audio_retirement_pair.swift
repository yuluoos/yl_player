// Experimental two-node oracle comparison. Silent output is not an audibility test.
import AVFAudio
import Foundation
import Darwin

func rawUs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000 }
final class Journal {
  private let lock = NSLock()
  private var rows: [[String: Any]] = []
  func record(_ kind: String, _ ordinal: Int) {
    let time = rawUs()
    lock.lock(); defer { lock.unlock() }
    rows.append(["kind": kind, "ordinal": ordinal, "rawUs": time])
  }
  func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows }
}
guard CommandLine.arguments.count == 2,
      ["steady", "transport"].contains(CommandLine.arguments[1]) else { exit(2) }
let scenario = CommandLine.arguments[1]
let engine = AVAudioEngine()
let reference = AVAudioPlayerNode()
let candidate = AVAudioPlayerNode()
let mixer = AVAudioMixerNode()
let pitch = AVAudioUnitTimePitch()
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
  channels: 2, interleaved: false)!
let journal = Journal()
let completionGroup = YlAudioCompletionGroup()
let retirement = AudioRetirementPrototype(generation: 1, route: 1)
for node in [reference, candidate, mixer, pitch] { engine.attach(node) }
pitch.pitch = 0; pitch.overlap = 8; pitch.rate = 1; pitch.bypass = true
engine.connect(reference, to: mixer, fromBus: 0, toBus: 0, format: format)
engine.connect(candidate, to: mixer, fromBus: 0, toBus: 1, format: format)
engine.connect(mixer, to: pitch, format: format)
engine.connect(pitch, to: engine.mainMixerNode, format: format)
engine.prepare()
for index in 0..<200 {
  autoreleasepool {
    for node in [reference, candidate] {
      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
      pcm.frameLength = 1024
      for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
        if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
      }
      if node === reference {
        node.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { _ in
          journal.record("reference", index)
        }
      } else {
        let once = completionGroup.makeCompletion { journal.record("rendered", index) }
        node.scheduleBuffer(pcm, completionCallbackType: .dataRendered) { _ in once() }
      }
    }
  }
}
try engine.start()
let startedUs = rawUs()
// Both nodes use the same future hardware host-time anchor.
let startHostTime = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.2)
let startTime = AVAudioTime(hostTime: startHostTime)
reference.play(at: startTime); candidate.play(at: startTime)
let schedule: [(String, UInt64)] = scenario == "transport"
  ? [("pause", 1_000_000), ("resume", 1_500_000), ("rate2", 2_000_000), ("rate1", 3_000_000)] : []
var nextAction = 0
var nextRow = 0
var samples: [[String: Any]] = []
var actions: [[String: Any]] = []

repeat {
  if nextAction < schedule.count, rawUs()-startedUs >= schedule[nextAction].1 {
    let begin = rawUs(); let name = schedule[nextAction].0
    switch name {
    case "pause": reference.pause(); candidate.pause()
    case "resume":
      let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: 0.05))
      reference.play(at: when); candidate.play(at: when)
    case "rate2": pitch.rate = 2; pitch.bypass = false
    case "rate1": pitch.rate = 1; pitch.bypass = true
    default: fatalError("Unknown action")
    }
    actions.append(["name": name, "startedUs": begin, "endedUs": rawUs()]); nextAction += 1
  }
  let begin = rawUs()
  let latency = candidate.outputPresentationLatency
  let referenceLatency = reference.outputPresentationLatency
  let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
  let maxFrames = engine.outputNode.auAudioUnit.maximumFramesToRender
  let quantum = Double(maxFrames) / outputRate
  let now = rawUs()
  let valid = latency.isFinite && latency > 0 && quantum.isFinite && quantum > 0
    && latency < Double(UInt64.max)/1_000_000 && quantum < Double(UInt64.max)/1_000_000
  retirement.observe(valid ? .init(observedUs: begin, downstreamUs: UInt64(ceil(latency*1_000_000)),
    quantumUs: UInt64(ceil(quantum*1_000_000)), route: 1) : nil, nowUs: now)
  let current = journal.snapshot()
  for event in current.dropFirst(nextRow) where event["kind"] as? String == "rendered" {
    let ordinal = event["ordinal"] as! Int
    let ticket = AudioRetirementPrototype.Ticket(generation: 1) { journal.record("candidate", ordinal) }
    _ = retirement.rendered(ticket, atUs: event["rawUs"] as! UInt64, nowUs: rawUs())
  }
  nextRow = current.count
  for callback in retirement.poll(nowUs: rawUs()) { callback() }
  let refTime = reference.lastRenderTime.flatMap { reference.playerTime(forNodeTime: $0) }
  let candTime = candidate.lastRenderTime.flatMap { candidate.playerTime(forNodeTime: $0) }
  samples.append(["startedUs": begin, "endedUs": rawUs(), "latency": latency,
    "referenceLatency": referenceLatency, "quantumSeconds": quantum,
    "maximumFramesToRender": maxFrames, "outputSampleRate": outputRate,
    "rate": pitch.rate, "bypass": pitch.bypass, "referencePlaying": reference.isPlaying,
    "candidatePlaying": candidate.isPlaying,
    "referenceSampleTime": refTime.map { $0.sampleTime as Any } ?? NSNull(),
    "candidateSampleTime": candTime.map { $0.sampleTime as Any } ?? NSNull(),
    "pending": retirement.pendingCount,
    "failure": retirement.failure.map { $0.rawValue as Any } ?? NSNull()])
  RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
} while rawUs()-startedUs < 8_000_000
let endedUs = rawUs()
let events = journal.snapshot()
let pendingBeforeStop = retirement.pendingCount
let failureBeforeStop = retirement.failure
reference.stop(); candidate.stop(); reference.reset(); candidate.reset()
engine.stop()
retirement.resetAfterOutputStop(generation: 2, route: 1, nowUs: rawUs())
for node in [reference, candidate, mixer, pitch] { engine.disconnectNodeOutput(node); engine.detach(node) }
let result: [String: Any] = ["scenario": scenario, "pid": ProcessInfo.processInfo.processIdentifier,
  "startedUs": startedUs, "endedUs": endedUs, "startHostTime": startHostTime,
  "events": events, "samples": samples, "actions": actions,
  "peakPending": retirement.peakPending, "pendingBeforeStop": pendingBeforeStop,
  "pendingAfterStop": retirement.pendingCount,
  "failure": failureBeforeStop.map { $0.rawValue as Any } ?? NSNull()]
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
print("YL_RETIREMENT_PROBE=" + String(decoding: data, as: UTF8.self))
