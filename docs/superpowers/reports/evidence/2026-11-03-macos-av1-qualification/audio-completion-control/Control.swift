import AVFoundation
import Foundation

// Diagnostic only: identical engine and scheduling, varying native API overlap.
let engine = AVAudioEngine()
let output = engine.outputNode
let player = AVAudioPlayerNode()
let pitch = AVAudioUnitTimePitch()
let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
engine.attach(player); engine.attach(pitch)
engine.connect(player, to: pitch, format: format)
engine.connect(pitch, to: engine.mainMixerNode, format: format)
engine.connect(engine.mainMixerNode, to: output, format: format)
pitch.rate = 1; pitch.bypass = true
let gate = NSLock(), stats = NSLock()
let start = ProcessInfo.processInfo.systemUptime
let phaseLength = 90.0
var phase = 0
var samples = [0,0,0], over100 = [0,0,0], peak = [0.0,0.0,0.0], maxAge = [0.0,0.0,0.0]
var scheduled: Int64 = 0
var callbackCount = 0
func now() -> Double { ProcessInfo.processInfo.systemUptime }
func currentPhase() -> Int { min(1, Int((now() - start) / phaseLength)) }
func read() -> AVAudioTime? {
  guard let stamp = output.lastRenderTime, stamp.isHostTimeValid else { return nil }
  return player.playerTime(forNodeTime: AVAudioTime(hostTime: stamp.hostTime))
}
func submit() {
  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
  pcm.frameLength = 960
  for c in 0..<2 { pcm.floatChannelData![c].initialize(repeating: 0, count: 960) }
  player.scheduleBuffer(pcm, completionCallbackType: currentPhase() == 0 ? .dataPlayedBack : .dataRendered) { _ in
    stats.lock(); callbackCount += 1; stats.unlock()
    withExtendedLifetime(pcm) {}
  }
  scheduled += 960
}
for _ in 0..<50 { submit() }
engine.prepare(); try engine.start(); player.play()
let sampling = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "control.reader", qos: .userInitiated))
sampling.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
sampling.setEventHandler {
  let p = currentPhase(), began = now()
  
  let value = read()
  
  let duration = now() - began
  let age = value.map { now() - AVAudioTime.seconds(forHostTime: $0.hostTime) } ?? 0
  stats.lock()
  samples[p] += 1; peak[p] = max(peak[p], duration); maxAge[p] = max(maxAge[p], age)
  if duration > 0.1 { over100[p] += 1 }
  stats.unlock()
}
let pumping = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "control.pump", qos: .utility))
pumping.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
pumping.setEventHandler {
  let p = currentPhase()
  
  // Preserve actual played-back callback admission in all three phases.
  
  stats.lock(); let completed = callbackCount; stats.unlock()
  if scheduled / 960 - Int64(completed) < 50 { submit() }
  
}
sampling.resume(); pumping.resume()
let reporting = DispatchSource.makeTimerSource(queue: .main)
reporting.schedule(deadline: .now() + .seconds(10), repeating: .seconds(10))
reporting.setEventHandler {
  stats.lock()
  let item: [String:Any] = ["elapsed":now()-start,"phase":currentPhase(),"modes":["singleReaderPlayedBack","singleReaderRendered","unused"],"samples":samples,"readsOver100ms":over100,"maximumReadSeconds":peak,"maximumHostAgeSeconds":maxAge,"callbacks":callbackCount]
  stats.unlock()
  print(String(data:try! JSONSerialization.data(withJSONObject:item,options:[.sortedKeys]),encoding:.utf8)!); fflush(stdout)
  if now()-start >= phaseLength*2 {
    sampling.cancel(); pumping.cancel(); player.stop(); engine.stop(); exit(0)
  }
}
reporting.resume()
dispatchMain()
