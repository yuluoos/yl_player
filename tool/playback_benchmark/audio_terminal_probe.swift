// Silent, tool-only experiment with production ledger and a held real EOF tail.
import AVFAudio
import Foundation
import Darwin
func rawUs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)/1000 }
typealias Model = AudioTerminalBudgetPrototype<AVAudioPCMBuffer>
final class Journal {
  private let lock=NSLock()
  private var values:[(Model.Ticket,Bool,UInt64)]=[]
  func record(_ ticket:Model.Ticket,_ terminal:Bool) {
    let now=rawUs();lock.lock();values.append((ticket,terminal,now));lock.unlock()
  }
  func snapshot()->[(Model.Ticket,Bool,UInt64)] { lock.lock();defer{lock.unlock()};return values }
}
final class WeakPCM { weak var value:AVAudioPCMBuffer?;init(_ v:AVAudioPCMBuffer){value=v} }
guard CommandLine.arguments.count==2, ["single","pausedEOF","refill"].contains(CommandLine.arguments[1]) else { exit(2) }
let scenario=CommandLine.arguments[1]
let target=scenario=="refill" ? 2000 : scenario=="pausedEOF" ? 3 : 1
let ledger=YlManagedBufferLedger(maxBytes:24*8192)
let scope=try ledger.makeScope(maxBytes:24*8192)
scope.configureTimeline(try YlBoundedBufferPlan(minDurationMs:0,maxDurationMs:512,maxBytes:4*1024*1024))
let model=Model(scope:scope,maxCount:24,maxBytes:24*8192,maxDurationUs:24*21333)
let journal=Journal();let completions=YlAudioCompletionGroup()
let engine=AVAudioEngine();let player=AVAudioPlayerNode();let pitch=AVAudioUnitTimePitch()
let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:false)!
engine.attach(player);engine.attach(pitch)
pitch.pitch=0;pitch.overlap=8;pitch.rate=1;pitch.bypass=true
engine.connect(player,to:pitch,format:format);engine.connect(pitch,to:engine.mainMixerNode,format:format)
engine.prepare()
var accepted=0;var eventIndex=0
var pcmRefs:[WeakPCM]=[];var submissions:[[String:Any]]=[];var samples:[[String:Any]]=[];var actions:[[String:Any]]=[]
func checkpoint(_ phase:String) {
  let events:[[String:Any]]=journal.snapshot().map { ["ordinal":$0.0.ordinal,"terminal":$0.1,"rawUs":$0.2] }
  let row:[String:Any]=["phase":phase,"scenario":scenario,"pid":ProcessInfo.processInfo.processIdentifier,
    "rawUs":rawUs(),"accepted":accepted,"pending":model.pendingCount,"pendingBytes":model.pendingBytes,
    "pendingDurationUs":model.pendingDurationUs,"ledgerBytes":ledger.snapshot.currentBytes,
    "ledgerPeak":ledger.snapshot.peakBytes,"timelineUs":scope.bufferedDurationUs,"peakCount":model.peakCount,
    "drained":model.drained,"inputFinished":model.inputFinished,"alivePCM":pcmRefs.filter{$0.value != nil}.count,
    "submissions":submissions,"events":events,"samples":samples,"actions":actions]
  FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])+Data([10]))
  guard readLine()=="continue" else { exit(3) }
}
func submit() {
  autoreleasepool {
    for submission in model.takeSubmissions() {
      guard let pcm=submission.payload else { preconditionFailure("Payload retired before schedule") }
      let ticket=submission.ticket;let terminal=submission.isTerminal
      submissions.append(["ordinal":ticket.ordinal,"terminal":terminal,"frames":pcm.frameLength,"rawUs":rawUs()])
      let done=completions.makeCompletion { journal.record(ticket,terminal) }
      player.scheduleBuffer(pcm,completionCallbackType:terminal ? .dataPlayedBack : .dataRendered) { _ in done() }
    }
  }
}
func pump(to limit:Int) {
  while accepted<limit {
    let status:Model.Admission=autoreleasepool {
      model.enqueue(ptsUs:Int64(accepted)*21333,durationUs:21333,bytes:8192) {
        let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1024)!
        pcm.frameLength=1024
        for b in UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList) {
          if let ptr=b.mData { memset(ptr,0,Int(b.mDataByteSize)) }
        }
        pcmRefs.append(WeakPCM(pcm));return pcm
      }
    }
    if status == .backpressure { break }
    precondition(status == .accepted,"Unexpected admission: \(status)")
    accepted += 1
  }
  submit()
}
func poll() {
  let events=journal.snapshot()
  for e in events.dropFirst(eventIndex) { if e.1 { model.playedBack(e.0) } else { model.rendered(e.0) } }
  eventIndex=events.count
  let nodeTime=player.lastRenderTime.flatMap{player.playerTime(forNodeTime:$0)}
  samples.append(["rawUs":rawUs(),"pending":model.pendingCount,"bytes":model.pendingBytes,
    "durationUs":model.pendingDurationUs,"ledgerBytes":ledger.snapshot.currentBytes,"drained":model.drained,
    "playing":player.isPlaying,"sampleTime":nodeTime.map{$0.sampleTime as Any} ?? NSNull()])
}
func runUntil(_ limit:UInt64, _ condition:()->Bool) {
  let start=rawUs()
  while !condition() && rawUs()-start<limit {
    poll();RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01))
  }
  poll()
}
checkpoint("configured")
try engine.start()
if scenario=="pausedEOF" { player.play();player.pause();actions.append(["name":"pause","rawUs":rawUs()]) }
if scenario=="refill" {
  player.play();actions.append(["name":"play","rawUs":rawUs()])
  for milestone in [200,2000] {
    let start=rawUs()
    repeat {
      poll();pump(to:milestone);RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01))
    } while (accepted<milestone || model.pendingCount>1) && rawUs()-start<60_000_000
    // Allow callback shell retirement to settle without ever submitting the held tail.
    runUntil(200_000) { false }
    actions.append(["name":"starved","rawUs":rawUs(),"accepted":accepted])
    checkpoint("holding\(milestone)")
  }
} else { pump(to:target) }
model.finishInput();actions.append(["name":"EOF","rawUs":rawUs(),"playing":player.isPlaying]);submit()
if scenario=="pausedEOF" { runUntil(300_000) { false } }
if scenario != "refill" { player.play();actions.append(["name":"play","rawUs":rawUs()]) }
runUntil(3_000_000) { model.drained }
runUntil(200_000) { false }
checkpoint("observed")
player.stop();player.reset();engine.stop();model.resetAfterOutputStop()
for node in [player,pitch] { engine.disconnectNodeOutput(node);engine.detach(node) }
checkpoint("disposed")
