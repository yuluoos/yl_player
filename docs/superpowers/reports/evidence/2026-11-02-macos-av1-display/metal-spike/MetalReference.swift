import AppKit
import AVFoundation
import CoreMedia
import Metal
import QuartzCore
import CoreImage
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
let device = MTLCreateSystemDefaultDevice()!
let commands = device.makeCommandQueue()!
let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
let layer = CAMetalLayer()
layer.device = device
layer.pixelFormat = .bgra8Unorm
layer.framebufferOnly = false
layer.maximumDrawableCount = 3
layer.displaySyncEnabled = true
layer.drawableSize = CGSize(width:320,height:180)
layer.frame = CGRect(x:40,y:40,width:320,height:180)
view.layer!.addSublayer(layer)
window.title = "AV1 Metal 呈现对照"
window.orderFrontRegardless()
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
let queue = DispatchQueue(label: "metal.reference", qos: .userInitiated)
let timer = DispatchSource.makeTimerSource(queue: queue)
let total = Int(CommandLine.arguments[2])!
var next = 0
var presented = 0
var dropped = 0
var late = 0
var maximumDelay = 0.0
var minimumLead = 1.0
var start = 0.0
let colorSpace = CGColorSpaceCreateDeviceRGB()
// Compile and warm the conversion before measuring timed presentation.
let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 320, height: 180, mipmapped: false)
descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
let warmTexture = device.makeTexture(descriptor: descriptor)!
let warmCommand = commands.makeCommandBuffer()!
context.render(CIImage(cvPixelBuffer: pixels[0]), to: warmTexture, commandBuffer: warmCommand,
 bounds: CGRect(x:0,y:0,width:320,height:180), colorSpace: colorSpace)
warmCommand.commit()
warmCommand.waitUntilCompleted()
precondition(warmCommand.status == .completed)
func submitDue() {
 let now = CACurrentMediaTime()
 while next < total && next - presented - dropped < 3 && start + Double(next)/24 <= now + 0.1 {
  autoreleasepool {
   let frame = next
   let target = start + Double(frame)/24
   let drawable = layer.nextDrawable()!
   let command = commands.makeCommandBuffer()!
   context.render(CIImage(cvPixelBuffer: pixels[frame % 96]), to: drawable.texture, commandBuffer: command,
    bounds: CGRect(x:0,y:0,width:320,height:180), colorSpace: colorSpace)
   minimumLead = min(minimumLead, target - CACurrentMediaTime())
   drawable.addPresentedHandler { receipt in
    let actual = receipt.presentedTime
    queue.async {
     if actual == 0 { dropped += 1 }
     else {
      presented += 1
      maximumDelay = max(maximumDelay, actual - target)
      if actual - target > 1.0/24 { late += 1 }
     }
     if actual == 0 || actual - target > 1.0/24 {
      print("METAL_BAD",frame,"target",target,"actual",actual)
      fflush(stdout)
     }
    }
   }
   command.present(drawable, atTime: target)
   command.commit()
   next += 1
  }
 }
}
var started = false
var prepared = false
var preparing = false
Timer.scheduledTimer(withTimeInterval:0.05,repeats:true) { waiter in
 guard window.occlusionState.contains(.visible) else {return}
 if !prepared {
  if preparing {return}
  preparing = true
  let drawable = layer.nextDrawable()!
  let command = commands.makeCommandBuffer()!
  context.render(CIImage(cvPixelBuffer: pixels[0]), to: drawable.texture, commandBuffer: command,
   bounds: CGRect(x:0,y:0,width:320,height:180), colorSpace: colorSpace)
  drawable.addPresentedHandler { receipt in
   let actual = receipt.presentedTime
   DispatchQueue.main.async {
    print("METAL_PREFLIGHT", actual)
    fflush(stdout)
    prepared = actual > 0
    preparing = false
   }
  }
  command.present(drawable)
  command.commit()
  return
 }
 waiter.invalidate()
 queue.sync { start = CACurrentMediaTime() + 0.1 }
 started = true
 timer.setEventHandler {submitDue()}
 timer.schedule(deadline:.now(),repeating:.milliseconds(10),leeway:.milliseconds(1))
 timer.resume()
}
Timer.scheduledTimer(withTimeInterval:1,repeats:true) { _ in
 guard started else {return}
 let snapshot = queue.sync {(next,presented,dropped,late,maximumDelay,minimumLead)}
 print("METAL",snapshot.0,snapshot.1,snapshot.2,snapshot.3,"delay",snapshot.4,"lead",snapshot.5,"visible",window.occlusionState.contains(.visible))
 fflush(stdout)
 if snapshot.2 > 0 {exit(1)}
 if snapshot.1 == total {exit(0)}
}
app.run()
