import Foundation
import CoreVideo

// Standalone harness for the real lease owner. These two unrelated domain values
// avoid linking the engine graph; ownership and output code are compiled intact.
struct YlAppleSessionIdentity: Equatable {
  let sessionId: String
  let loadRequestId: String
}
struct NativePlayerError: Error {}
struct YlPresentationClockSnapshot {}
struct YlFrameEnvelope {}

final class RetentionOutput: YlRetainedVideoOutput, YlNativeVideoSurfaceOutput {
  let textureId: Int64 = 42
  let nativeViewType: String? = "yl_player_apple/video"
  var onRenderFailure: ((NativePlayerError) -> Void)?
  var reservation: AnyObject?
  var published = 0
  func publish(_ pixelBuffer: CVPixelBuffer?) { published += 1 }
  func publish(_ pixelBuffer: CVPixelBuffer, retaining reservation: AnyObject?) {
    published += 1
    self.reservation = reservation
  }
  func resize(width: Int, height: Int) {}
  func clear() { reservation = nil }
  func dispose() { clear() }
}

@main
struct LeaseRetentionTests {
  static func main() {
    var pixel: CVPixelBuffer?
    precondition(CVPixelBufferCreate(kCFAllocatorDefault, 2, 2,
      kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    let frame = pixel!
    let output = RetentionOutput()
    var accepted: [YlAppleSessionIdentity] = []
    let owner = YlAppleTextureOwner(output: output, onFrame: { accepted.append($0) })
    let a = YlAppleSessionIdentity(sessionId: "a", loadRequestId: "a")
    let lease = owner.makeLease(identity: a)
    let binding = YlAppleAvTextureBinding(textureId: 42)
    binding.lease = lease
    var token: NSObject? = NSObject()
    weak var retained = token
    ylPublishVideoFrame(frame, retaining: token, to: binding)
    token = nil
    precondition(retained != nil, "A private lease must retain the frame budget")
    precondition(output.published == 0 && accepted.isEmpty, "Private frames cannot publish public FirstFrame")
    owner.commit(lease)
    precondition(output.reservation === retained, "Commit must transfer budget ownership to the output")
    precondition(output.published == 1 && accepted == [a])
    lease.clear()
    precondition(retained == nil, "Clearing the committed sample must release its budget")
    retained = nil

    for stop in [false, true] {
      let candidate = owner.makeLease(identity: a)
      var pending: NSObject? = NSObject()
      weak var retainedPending = pending
      ylPublishVideoFrame(frame, retaining: pending, to: candidate)
      pending = nil
      precondition(retainedPending != nil)
      if stop { owner.stop() } else { candidate.clear() }
      precondition(retainedPending == nil, "Clear and Stop must release private pending budgets")
      retainedPending = nil
    }

    let retired = owner.makeLease(identity: a)
    owner.commit(retired)
    let replacement = owner.makeLease(identity: .init(sessionId: "b", loadRequestId: "b"))
    owner.commit(replacement)
    var late: NSObject? = NSObject()
    weak var retainedLate = late
    ylPublishVideoFrame(frame, retaining: late, to: retired)
    late = nil
    precondition(retainedLate == nil, "Retired lease must reject late frame budgets")
    retainedLate = nil

    let candidate = owner.makeLease(identity: a)
    var pending: NSObject? = NSObject()
    weak var retainedPending = pending
    ylPublishVideoFrame(frame, retaining: pending, to: candidate)
    pending = nil
    precondition(retainedPending != nil)
    owner.dispose()
    precondition(retainedPending == nil, "Owner disposal must release uncommitted candidates")
    retainedPending = nil
    print("PASS: lease pending/committed budget lifetime, binding propagation, FirstFrame authority, clear/stop/dispose, retired callback rejection")
  }
}
