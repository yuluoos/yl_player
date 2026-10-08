// Exact frame markers at the player-node tap; the final mixer is muted.
// This measures graph delivery, not speaker output, AV sync or a media clock.
import AVFAudio
import Foundation
import Darwin
func rawUs()->UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)/1000 }
typealias Model=AudioTerminalBudgetPrototype<AVAudioPCMBuffer>
final class Journal {
  let lock=NSLock();var values:[(Model.Ticket,Bool)]=[]
  func add(_ t:Model.Ticket,_ p:Bool){lock.lock();values.append((t,p));lock.unlock()}
  func snapshot()->[(Model.Ticket,Bool)]{lock.lock();defer{lock.unlock()};return values}
}
final class Markers {
  private let lock=NSLock();private var frames=0;private var zeros=0;private var gaps=0
  private var errors:[String]=[]
  func consume(_ buffer:AVAudioPCMBuffer) {
    lock.lock();defer{lock.unlock()}
    guard let channel=buffer.floatChannelData?[0] else {if errors.count<10{errors.append("missing channel")};return}
    for i in 0..<Int(buffer.frameLength) {
      let v=channel[i]
      if v==0 {if frames>0{zeros += 1};continue}
      let expected=Float(frames+1)/4194304
      if v != expected && errors.count<10 {errors.append("frame \(frames+1): \(v) != \(expected)")}
      frames += 1;gaps += zeros;zeros=0
    }
  }
  func snapshot()->[String:Any]{lock.lock();defer{lock.unlock()};return ["frames":frames,"interiorZeroFrames":gaps,"errors":errors]}
}
guard CommandLine.arguments.count==2,["steady","starve"].contains(CommandLine.arguments[1]) else{exit(2)}
let scenario=CommandLine.arguments[1];let target=scenario=="steady" ? 2000 : 100
let ledger=YlManagedBufferLedger(maxBytes:196608);let scope=try ledger.makeScope(maxBytes:196608)
scope.configureTimeline(try YlBoundedBufferPlan(minDurationMs:0,maxDurationMs:512,maxBytes:4*1024*1024))
let q=Model(scope:scope,maxCount:24,maxBytes:196608,maxDurationUs:511992)
let events=Journal();let markers=Markers();let completions=YlAudioCompletionGroup()
let engine=AVAudioEngine();let player=AVAudioPlayerNode();let pitch=AVAudioUnitTimePitch()
let format=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:2,interleaved:false)!
engine.attach(player);engine.attach(pitch);pitch.bypass=true;pitch.rate=1;pitch.pitch=0;pitch.overlap=8
engine.connect(player,to:pitch,format:format);engine.connect(pitch,to:engine.mainMixerNode,format:format)
engine.mainMixerNode.outputVolume=0
player.installTap(onBus:0,bufferSize:1024,format:format){buffer,_ in markers.consume(buffer)}
engine.prepare()
var accepted=0;var eventIndex=0;var submissions:[[String:Any]]=[];var samples:[[String:Any]]=[];var actions:[[String:Any]]=[]
var stallStart:UInt64?;var resumed=false;var notedFallback=false
func submit(){autoreleasepool{
  for s in q.takeSubmissions(){
    let ticket=s.ticket;let played=s.usesPlayedBack
    submissions.append(["ordinal":ticket.ordinal,"playedBack":played])
    let once=completions.makeCompletion{events.add(ticket,played)}
    player.scheduleBuffer(s.payload!,completionCallbackType:played ? .dataPlayedBack : .dataRendered){_ in once()}
  }
}}
func pump(_ limit:Int){
  while accepted<limit {
    let ordinal=accepted
    let outcome=q.enqueue(ptsUs:Int64(ordinal)*21333,durationUs:21333,bytes:8192){
      let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:1024)!;pcm.frameLength=1024
      for channel in 0..<2 {for frame in 0..<1024 {pcm.floatChannelData![channel][frame]=Float(ordinal*1024+frame+1)/4194304}}
      return pcm
    }
    if outcome == .backpressure {break}
    precondition(outcome == .accepted,"Unexpected admission \(outcome)");accepted += 1
  }
  if accepted==target && !q.inputFinished {q.finishInput();actions.append(["name":"EOF","rawUs":rawUs()])}
  submit()
}
func checkpoint(_ phase:String){
  let rows:[[String:Any]]=events.snapshot().map{["ordinal":$0.0.ordinal,"playedBack":$0.1]}
  let row:[String:Any]=["phase":phase,"scenario":scenario,"pid":ProcessInfo.processInfo.processIdentifier,
    "accepted":accepted,"pending":q.pendingCount,"ledgerBytes":ledger.snapshot.currentBytes,
    "ledgerPeak":ledger.snapshot.peakBytes,"drained":q.drained,"marker":markers.snapshot(),
    "fallbackCount":q.fallbackCount,"events":rows,"submissions":submissions,"samples":samples,"actions":actions]
  FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])+Data([10]))
  guard readLine()=="continue" else{exit(3)}
}
checkpoint("configured")
try engine.start();pump(scenario=="starve" ? 40 : target);player.play()
let start=rawUs();var drainedAt:UInt64?
repeat {
  let now=rawUs();let current=events.snapshot()
  for e in current.dropFirst(eventIndex){if e.1{q.playedBack(e.0)}else{q.rendered(e.0)}}
  eventIndex=current.count
  if scenario=="starve" && accepted==40 && q.pendingCount==1 && stallStart==nil {
    stallStart=now;actions.append(["name":"starved","rawUs":now])
  }
  if let stalled=stallStart,!resumed,now-stalled>=300000 {
    resumed=true;actions.append(["name":"refill","rawUs":now])
  }
  pump(scenario=="starve" && !resumed ? 40 : target)
  q.observePlayback(playing:true,nowUs:now)
  if q.fallbackCount==1 && !notedFallback {notedFallback=true;actions.append(["name":"fallback","rawUs":now])}
  submit()
  samples.append(["rawUs":now,"pending":q.pendingCount,"bytes":q.pendingBytes,"durationUs":q.pendingDurationUs,
    "ledgerBytes":ledger.snapshot.currentBytes])
  if q.drained && drainedAt==nil {drainedAt=now}
  RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01))
} while rawUs()-start<60_000_000 && (drainedAt==nil || rawUs()-drainedAt!<300000)
checkpoint("observed")
player.removeTap(onBus:0);player.stop();player.reset();engine.stop();q.resetAfterOutputStop()
for node in [player,pitch]{engine.disconnectNodeOutput(node);engine.detach(node)}
checkpoint("disposed")
