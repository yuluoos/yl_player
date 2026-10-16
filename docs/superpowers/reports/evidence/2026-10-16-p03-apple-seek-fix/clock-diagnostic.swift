import AppKit
import AVFoundation
let app = NSApplication.shared
let layer = AVSampleBufferDisplayLayer()
func show(_ label: String) { print(label, "control", layer.controlTimebase != nil, "effective", CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase)) }
func tick() { RunLoop.current.run(until: Date().addingTimeInterval(0.15)) }
show("initial")
var clock: CMTimebase?
CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock)
CMTimebaseSetTime(clock!, time: CMClockGetTime(CMClockGetHostTimeClock()))
layer.controlTimebase = clock!
tick(); show("frozen")
CMTimebaseSetRate(clock!, rate: 1)
tick(); show("rate1 attached")
layer.controlTimebase = nil
tick(); show("nil restored")
