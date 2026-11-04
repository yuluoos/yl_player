import AppKit
import AVFoundation
import CoreMedia

// Diagnostic rings retain scalar timings only. No render work in the display callback.
final class TraceRing {
 let lock = NSLock()
 var values = [[Double]]()
 func record(_ row: [Double]) {
  lock.lock(); defer { lock.unlock() }
  values.append(row)
  if values.count > 512 { values.removeFirst() }
 }
 func dump(_ kind: String) {
  lock.lock(); let copy = values; lock.unlock()
  let data = try! JSONSerialization.data(withJSONObject: ["kind":kind,"rows":copy], options: [.sortedKeys])
  print("TRACE", String(data:data,encoding:.utf8)!)
 }
}
let displayTrace = TraceRing(), mainTrace = TraceRing(), enqueueTrace = TraceRing()
var displayLink: CVDisplayLink?
precondition(CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &displayLink) == kCVReturnSuccess)
precondition(CVDisplayLinkSetOutputCallback(displayLink!, { _, current, output, _, _, _ in
 let now = ProcessInfo.processInfo.systemUptime
 let frequency = CVGetHostClockFrequency()
 displayTrace.record([now, Double(current.pointee.hostTime)/frequency, Double(output.pointee.hostTime)/frequency])
 return kCVReturnSuccess
}, nil) == kCVReturnSuccess)
precondition(CVDisplayLinkStart(displayLink!) == kCVReturnSuccess)
let heartbeat = Timer.scheduledTimer(withTimeInterval:0.01,repeats:true) { _ in
 mainTrace.record([ProcessInfo.processInfo.systemUptime])
}
print("TRACE_ORIGIN",ProcessInfo.processInfo.systemUptime,Date().timeIntervalSince1970)

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 260), styleMask: [.titled], backing: .buffered, defer: false)
window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.canJoinAllApplications]
window.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 3)
window.title = "AV1 原生显示队列对照"
let area = NSScreen.main!.visibleFrame
window.setFrameOrigin(NSPoint(x: area.maxX-window.frame.width-24,y: area.maxY-window.frame.height-24))
let view = window.contentView!
view.wantsLayer = true
let layer = AVSampleBufferDisplayLayer()
layer.frame = CGRect(x:40,y:40,width:320,height:180)
view.layer!.addSublayer(layer)
window.orderFrontRegardless()
func exposure(_ reason: String) {
 let wr = window.convertToScreen(view.convert(layer.frame, to:nil))
 let aperture = CGRect(x: wr.minX,y: CGDisplayBounds(CGMainDisplayID()).height-wr.maxY,width:wr.width,height:wr.height)
 let all=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements], kCGNullWindowID) as? [[String:Any]] ?? []
 var occluders:[String]=[]
 var found=false
 for row in all {
   if row[kCGWindowNumber as String] as? Int == window.windowNumber {found=true;break}
   if let b=row[kCGWindowBounds as String] as? [String:Double],
      let x=b["X"],let y=b["Y"],let w=b["Width"],let h=b["Height"] {
     let overlap=CGRect(x:x,y:y,width:w,height:h).intersection(aperture)
     if !overlap.isNull,overlap.width>1,overlap.height>1,let pid=row[kCGWindowOwnerPID as String] as? Int32 {
       let owner=NSRunningApplication(processIdentifier:pid)?.bundleIdentifier ?? String(pid)
       let level=row[kCGWindowLayer as String] ?? "?"
       let percent=Int(100*overlap.width*overlap.height/(wr.width*wr.height))
       occluders.append("\(owner)@\(level)=\(percent)%")
     }
   }
 }
 let session=CGSessionCopyCurrentDictionary() as? [String:Any]
 print("EXPOSURE",reason,"onList",found,"activeSpace",window.isOnActiveSpace,"visible",window.occlusionState.contains(.visible),"lock",session?["CGSSessionScreenIsLocked"] ?? false,"above",occluders)
 fflush(stdout)
}
let token=NotificationCenter.default.addObserver(forName:NSWindow.didChangeOcclusionStateNotification,object:window,queue:.main){_ in exposure("change")}
let raw = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
var pixels:[CVPixelBuffer] = []
let planeBytes=320*180
raw.withUnsafeBytes { ptr in
 for n in 0..<96 {
  var buffer:CVPixelBuffer?
  precondition(CVPixelBufferCreate(nil,320,180,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,nil,&buffer)==0)
  let pixel=buffer!
  CVPixelBufferLockBaseAddress(pixel,[])
  for i in 0..<2 {
   let addr=CVPixelBufferGetBaseAddressOfPlane(pixel,i)!, stride=CVPixelBufferGetBytesPerRowOfPlane(pixel,i)
   for row in 0..<CVPixelBufferGetHeightOfPlane(pixel,i) {
    memcpy(addr+row*stride,ptr.baseAddress!+n*planeBytes*3/2+i*planeBytes+row*320,320)
   }
  }
  CVPixelBufferUnlockBaseAddress(pixel,[])
  CVBufferSetAttachment(pixel,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_601_4,.shouldPropagate)
  pixels.append(pixel)
 }
}
var format:CMVideoFormatDescription?
precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator:nil,imageBuffer:pixels[0],formatDescriptionOut:&format)==0)
let host=CMClockGetHostTimeClock()
var base:CMTimebase?
precondition(CMTimebaseCreateWithSourceClock(allocator:nil,sourceClock:host,timebaseOut:&base)==0)
layer.controlTimebase=base
let q=DispatchQueue(label:"reference.video",qos:.userInitiated)
let timer=DispatchSource.makeTimerSource(queue:q)
var n=0
var minLead=1.0
func enqueueDue() {
 let now=CMTimeGetSeconds(CMTimebaseGetTime(base!))
 while n<12960 && Double(n)/24<=now+0.050 && layer.sampleBufferRenderer.isReadyForMoreMediaData {
  var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:24),presentationTimeStamp:CMTime(value:Int64(n),timescale:24),decodeTimeStamp:.invalid)
  var sample:CMSampleBuffer?
  precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator:nil,imageBuffer:pixels[n%96],formatDescription:format!,sampleTiming:&timing,sampleBufferOut:&sample)==0)
  if n>0 {minLead=min(minLead,Double(n)/24-CMTimeGetSeconds(CMTimebaseGetTime(base!)))}
  let began = ProcessInfo.processInfo.systemUptime
  let media = CMTimeGetSeconds(CMTimebaseGetTime(base!))
  layer.sampleBufferRenderer.enqueue(sample!)
  enqueueTrace.record([began,ProcessInfo.processInfo.systemUptime,Double(n)/24,media])
  n+=1
 }
}
timer.setEventHandler { enqueueDue() }
CMTimebaseSetTime(base!, time: .zero)
var started = false
var phase = "display-and-main"
var previousDrops = 0
Timer.scheduledTimer(withTimeInterval:0.05,repeats:true) { waiter in
 guard window.occlusionState.contains(.visible) else {return}
 waiter.invalidate()
 q.sync { enqueueDue() }
 exposure("start")
 // Allow the paused first image to reach the compositor before starting time.
 DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
  exposure("play")
  layer.sampleBufferRenderer.loadVideoPerformanceMetrics { m in
   if let m { print("PREFLIGHT_METRICS", m.totalNumberOfFrames, m.numberOfDroppedFrames); fflush(stdout) }
  }
  CMTimebaseSetRateAndAnchorTime(base!,rate:1,anchorTime:.zero,immediateSourceTime:CMClockGetTime(host))
  started = true
  print("PHASE", ProcessInfo.processInfo.systemUptime, phase)
  DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
   CVDisplayLinkStop(displayLink!)
   phase = "main-only"
   print("PHASE", ProcessInfo.processInfo.systemUptime, phase)
  }
  DispatchQueue.main.asyncAfter(deadline: .now() + 360) {
   heartbeat.invalidate()
   phase = "neither"
   print("PHASE", ProcessInfo.processInfo.systemUptime, phase)
  }
  timer.schedule(deadline:.now(),repeating:.milliseconds(10),leeway:.milliseconds(1));timer.resume()
 }
}
Timer.scheduledTimer(withTimeInterval:1,repeats:true) { _ in
 guard started else {return}
 layer.sampleBufferRenderer.loadVideoPerformanceMetrics { metrics in
  DispatchQueue.main.async {
   guard let m=metrics else {exit(2)}
   let stats=q.sync { (n,minLead) }
   print("REFERENCE",phase,ProcessInfo.processInfo.systemUptime,stats.0,stats.1,m.totalNumberOfFrames,m.numberOfDroppedFrames,m.numberOfCorruptedFrames,window.occlusionState.contains(.visible))
   fflush(stdout)
   if m.numberOfDroppedFrames > previousDrops || m.numberOfCorruptedFrames>0 {
    print("DROP_PHASE", phase)
    previousDrops = m.numberOfDroppedFrames
    exposure("drop")
    displayTrace.dump("display"); mainTrace.dump("main"); enqueueTrace.dump("enqueue")
    fflush(stdout)
   }
   if m.totalNumberOfFrames>=12960 {exit(m.numberOfDroppedFrames == 0 && m.numberOfCorruptedFrames == 0 ? 0 : 1)}
  }
 }
}
app.run()
