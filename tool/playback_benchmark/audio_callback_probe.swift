// Standalone diagnostic: mirror the system output graph and callback type.
// This is not the Flutter player, a performance baseline, or a release test.
import AVFAudio
import Foundation

final class DeliveredCallbackMarker: NSObject {
  let ordinal: Int
  init(_ ordinal: Int) { self.ordinal = ordinal }
}

final class WeakMarker {
  weak var value: DeliveredCallbackMarker?
  init(_ value: DeliveredCallbackMarker) { self.value = value }
}

final class DeliveryCount {
  private let lock = NSLock()
  private var value = 0
  func delivered(_ marker: DeliveredCallbackMarker) {
    lock.lock()
    value += 1
    lock.unlock()
    withExtendedLifetime(marker) {}
  }
  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let timePitch = AVAudioUnitTimePitch()
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
  channels: 2, interleaved: false)!
let delivery = DeliveryCount()
var markers: [WeakMarker] = []
engine.attach(player)
engine.attach(timePitch)
timePitch.pitch = 0
timePitch.overlap = 8
engine.connect(player, to: timePitch, format: format)
engine.connect(timePitch, to: engine.mainMixerNode, format: format)
engine.prepare()

func checkpoint(_ phase: String) {
  let alive = markers.compactMap { $0.value }
  let firstAddress = alive.first.map { String(UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()), radix: 16) }
  let record: [String: Any] = ["phase": phase, "pid": ProcessInfo.processInfo.processIdentifier,
    "delivered": delivery.count, "alive": alive.count,
    "firstAddress": firstAddress.map { "0x" + $0 } ?? NSNull() as Any]
  let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
  FileHandle.standardOutput.write(data + Data([10]))
}

func waitForObserver() {
  // The external collector has a deadline and sends one line after its probes.
  // Keep no temporary strong marker references alive across this wait.
  guard readLine() == "continue" else { exit(2) }
}

checkpoint("configured")
waitForObserver()
for index in 0..<200 {
  autoreleasepool {
    let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    pcm.frameLength = 1024
    for buffer in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
      if let bytes = buffer.mData { memset(bytes, 0, Int(buffer.mDataByteSize)) }
    }
    let marker = DeliveredCallbackMarker(index)
    markers.append(WeakMarker(marker))
    player.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { _ in
      delivery.delivered(marker)
    }
  }
}
try engine.start()
player.play()
let deadline = Date(timeIntervalSinceNow: 10)
while delivery.count < 200 && Date() < deadline {
  RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
}
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
checkpoint("played")
waitForObserver()
player.stop()
player.reset()
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
checkpoint("reset")
waitForObserver()
engine.stop()
engine.disconnectNodeOutput(player)
engine.disconnectNodeOutput(timePitch)
engine.detach(player)
engine.detach(timePitch)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.25))
checkpoint("disposed")
waitForObserver()
withExtendedLifetime((engine, player, timePitch)) {}
exit(delivery.count == 200 ? 0 : 1)
