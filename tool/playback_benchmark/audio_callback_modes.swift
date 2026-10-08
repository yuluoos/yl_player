// Bounded diagnostic of callback semantics, not physical presentation timing.
import AVFAudio
import Foundation
import Darwin

func rawUs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1000 }

final class EventJournal {
  private let lock = NSLock()
  private var values: [[String: Any]] = []
  func record(_ ordinal: Int, _ type: AVAudioPlayerNodeCompletionCallbackType) {
    let time = rawUs()
    lock.lock()
    values.append(["ordinal": ordinal, "rawUs": time, "callbackType": type.rawValue])
    lock.unlock()
  }
  func snapshot() -> [[String: Any]] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}

final class CallbackPayload: NSObject {}
final class WeakPayload {
  weak var value: CallbackPayload?
  init(_ value: CallbackPayload) { self.value = value }
}

let modes: [String: AVAudioPlayerNodeCompletionCallbackType] = [
  "consumed": .dataConsumed, "rendered": .dataRendered, "playedBack": .dataPlayedBack]
guard CommandLine.arguments.count == 3,
      let callbackType = modes[CommandLine.arguments[1]],
      ["steady", "transport"].contains(CommandLine.arguments[2]) else { exit(2) }
let mode = CommandLine.arguments[1]
let scenario = CommandLine.arguments[2]
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let pitch = AVAudioUnitTimePitch()
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
  channels: 2, interleaved: false)!
let completions = YlAudioCompletionGroup()
let journal = EventJournal()
var payloads: [WeakPayload] = []
engine.attach(player)
engine.attach(pitch)
pitch.pitch = 0
pitch.overlap = 8
pitch.rate = 1
pitch.bypass = true
engine.connect(player, to: pitch, format: format)
engine.connect(pitch, to: engine.mainMixerNode, format: format)
engine.prepare()

func checkpoint(_ phase: String, extra: [String: Any] = [:]) {
  var row = extra
  row.merge(["phase": phase, "mode": mode, "scenario": scenario,
    "pid": ProcessInfo.processInfo.processIdentifier,
    "alive": payloads.filter { $0.value != nil }.count]) { _, new in new }
  let data = try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
  FileHandle.standardOutput.write(data + Data([10]))
  guard readLine() == "continue" else { exit(3) }
}

checkpoint("configured")
let captureStartUs = rawUs()
for index in 0..<200 {
  autoreleasepool {
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    pcm.frameLength = 1024
    for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
      if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
    }
    let payload = CallbackPayload()
    payloads.append(WeakPayload(payload))
    let completion = completions.makeCompletion { withExtendedLifetime(payload) {} }
    player.scheduleBuffer(pcm, completionCallbackType: callbackType) { actualType in
      // Never query player/engine state on the system callback queue.
      journal.record(index, actualType)
      completion()
    }
  }
}
try engine.start()
let startedUs = rawUs()
player.play()
let playReturnedUs = rawUs()
var samples: [[String: Any]] = []
var actions: [[String: Any]] = []
let schedule: [(String, UInt64)] = scenario == "transport"
  ? [("pause", 1_000_000), ("resume", 1_500_000), ("rate2", 2_000_000), ("rate1", 3_000_000)] : []
var actionIndex = 0

func sample() {
  let begin = rawUs()
  let nodeTime = player.lastRenderTime
  let playerTime = nodeTime.flatMap { player.playerTime(forNodeTime: $0) }
  let row: [String: Any] = ["startedUs": begin,
    "sampleTime": playerTime.map { $0.sampleTime as Any } ?? NSNull(),
    "sampleRate": playerTime.map { $0.sampleRate as Any } ?? NSNull(),
    "nodeHostTime": nodeTime.map { $0.hostTime as Any } ?? NSNull(),
    "presentationLatency": player.outputPresentationLatency,
    "outputLatency": engine.outputNode.outputPresentationLatency,
    "rate": pitch.rate, "bypass": pitch.bypass, "playing": player.isPlaying]
  var finished = row
  finished["endedUs"] = rawUs()
  samples.append(finished)
}

repeat {
  if actionIndex < schedule.count, rawUs() - startedUs >= schedule[actionIndex].1 {
    let name = schedule[actionIndex].0
    let begin = rawUs()
    switch name {
    case "pause": player.pause()
    case "resume": player.play()
    case "rate2": pitch.rate = 2; pitch.bypass = false
    case "rate1": pitch.rate = 1; pitch.bypass = true
    default: fatalError("Unexpected action")
    }
    actions.append(["name": name, "startedUs": begin, "endedUs": rawUs()])
    actionIndex += 1
  }
  sample()
  RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
} while rawUs() - startedUs < 8_000_000
sample()
let endedUs = rawUs()
checkpoint("observed", extra: ["captureStartUs": captureStartUs, "startedUs": startedUs,
  "playReturnedUs": playReturnedUs, "endedUs": endedUs, "samples": samples,
  "actions": actions, "events": journal.snapshot()])
player.stop()
player.reset()
engine.stop()
engine.disconnectNodeOutput(player)
engine.disconnectNodeOutput(pitch)
engine.detach(player)
engine.detach(pitch)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
checkpoint("disposed")
withExtendedLifetime((engine, player, pitch, completions)) {}
exit(0)
