// macOS test helper. Only timestamps and normalized energy in the eight owned
// fixture tone bands leave the input callback. No microphone PCM is retained.
import AVFoundation
import AppKit
import CoreAudio
import Foundation

func builtinDevice(_ selector: AudioObjectPropertySelector) -> Bool {
  var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  var size = UInt32(MemoryLayout<AudioDeviceID>.size)
  var device = AudioDeviceID(0)
  guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
  address.mSelector = kAudioDevicePropertyTransportType
  var type = UInt32(0)
  return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &type) == noErr && type == kAudioDeviceTransportTypeBuiltIn
}

let args = CommandLine.arguments
guard args.count == 4 else { exit(2) }
let mode = args[1], run = args[2], url = URL(fileURLWithPath: args[3])
guard FileManager.default.createFile(atPath: url.path, contents: nil),
      let file = try? FileHandle(forWritingTo: url) else { exit(2) }
func emit(_ object: [String: Any]) {
  do {
    var value = object; value["runId"] = run
    var data = try JSONSerialization.data(withJSONObject: value)
    data.append(10); try file.write(contentsOf: data)
  } catch { exit(2) }
}

let engine = AVAudioEngine()
func start() throws {
  guard builtinDevice(kAudioHardwarePropertyDefaultInputDevice),
        builtinDevice(kAudioHardwarePropertyDefaultOutputDevice) else { emit(["error":"built-in devices required"]); exit(2) }
  if mode == "authorize" { emit(["authorized":true]); exit(0) }
  guard mode == "capture" else { exit(2) }
  let input = engine.inputNode, format = input.outputFormat(forBus: 0)
  let rate = format.sampleRate
  guard rate > 0, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
    emit(["error":"unsupported microphone format"]); exit(2)
  }
  let coefficients = [440,495,660,715,880,935,1100,1155].map { 2*cos(2*Double.pi*Double($0)/rate) }
  let count = Int((rate * 0.04).rounded())
  let weights = (0..<count).map { 0.5 - 0.5*cos(2*Double.pi*Double($0)/Double(count-1)) }
  input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(count*2), format: format) { buffer, when in
    guard when.isHostTimeValid, when.isSampleTimeValid, let channel = buffer.floatChannelData?[0] else { return }
    let frames = Int(buffer.frameLength)
    for offset in stride(from: 0, to: frames, by: count) where offset+count <= frames {
      var a = [Double](repeating: 0, count: 8), b = a
      var energy = 0.0
      for i in 0..<count {
        let x = Double(channel[offset+i])*weights[i]; energy += x*x
        for k in 0..<8 { let u = x+coefficients[k]*a[k]-b[k]; b[k]=a[k]; a[k]=u }
      }
      let powers = (0..<8).map { k -> Double in
        guard energy > 1e-12 else { return 0 }
        return max(0, 2*(a[k]*a[k]+b[k]*b[k]-coefficients[k]*a[k]*b[k])/(Double(count)*energy))
      }
      let host = AVAudioTime.seconds(forHostTime: when.hostTime) + Double(offset)/rate
      emit(["hostUs": Int64((host*1e6).rounded()), "sample": when.sampleTime+Int64(offset),
            "frames":count, "rate":rate, "bands": powers])
    }
  }
  try engine.start()
  emit(["ready":true,"builtinInput":true,"builtinOutput":true])
  let stop = url.appendingPathExtension("stop").path
  Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
    guard FileManager.default.fileExists(atPath: stop) else { return }
    timer.invalidate()
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    let sameRoute = builtinDevice(kAudioHardwarePropertyDefaultInputDevice) &&
      builtinDevice(kAudioHardwarePropertyDefaultOutputDevice)
    emit(["ended": sameRoute])
    exit(sameRoute ? 0 : 2)
  }
}

func authorized(_ granted: Bool) {
  DispatchQueue.main.async {
    guard granted else { emit(["error":"microphone access denied"]); exit(2) }
    do { try start() } catch { emit(["error":"audio input could not start"]); exit(2) }
  }
}
if mode == "authorize" {
  AVCaptureDevice.requestAccess(for: .audio, completionHandler: authorized)
} else {
  authorized(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
}
RunLoop.main.run()
