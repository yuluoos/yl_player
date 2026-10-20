import yl_player_media_core
import Foundation
import CoreVideo

enum YlApplePlatform: String {
  case ios, macos
  static var current: Self {
    #if os(iOS)
    return .ios
    #else
    return .macos
    #endif
  }
  var displayName: String { self == .ios ? "iOS" : "macOS" }
}

/// Immutable compatibility choices from the reviewed legacy implementations.
/// They are internal migration constraints, not public tuning controls.
struct YlAppleCompatibility {
  let platform: YlApplePlatform
  static let current = Self(platform: .current)
  // Preserve frames until their presentation time on both Apple platforms.
  var usesBackpressure: Bool { true }
  var preservesLiveResumeIntent: Bool { platform == .macos }
  var audioDurationUs: Int64 { platform == .ios ? 500_000 : 1_000_000 }
  var scalesAudioDuration: Bool { true }
  var batchesAudioInput: Bool { platform == .macos }
  // AVAudioUnitTimePitch rejects interleaved Float32 on iOS (-10868).
  // Keep converter buffers and the engine graph in the same planar format.
  var usesInterleavedPCM: Bool { false }
  var limitsVideoReservations: Bool { true }
  var retainsReplacementHls: Bool { platform == .ios }
  // P04 requires the same bounded live-HLS recovery on both Apple platforms.
  var reconnectsAvPlayer: Bool { true }
}

protocol YlTextureOutput: AnyObject {
  var textureId: Int64 { get }
  func publish(_ pixelBuffer: CVPixelBuffer?)
  func resize(width: Int, height: Int)
  func clear()
  func dispose()
}

/// Native presentation may retain a sample after publication returns. Carry the
/// frame's budget reservation with that sample rather than a reusable pixel pool.
protocol YlRetainedVideoOutput: YlTextureOutput {
  func publish(_ pixelBuffer: CVPixelBuffer, retaining reservation: AnyObject?)
}

func ylPublishVideoFrame(_ pixelBuffer: CVPixelBuffer, retaining reservation: AnyObject?,
                         to output: any YlTextureOutput) {
  if let retained = output as? any YlRetainedVideoOutput {
    retained.publish(pixelBuffer, retaining: reservation)
  } else {
    output.publish(pixelBuffer)
  }
}

/// Optional capability, so texture-only adapters and test doubles stay valid.
protocol YlNativeVideoSurfaceOutput: AnyObject {
  var nativeViewType: String? { get }
  var onRenderFailure: ((NativePlayerError) -> Void)? { get set }
}

protocol YlDisplayDriving: AnyObject {
  var isPaused: Bool { get set }
  func invalidate()
}

protocol YlLifecycleDriving: AnyObject {
  var onSuspend: (() -> Void)? { get set }
  var onResume: (() -> Void)? { get set }
  var onTerminate: (() -> Void)? { get set }
  var onMemoryWarning: (() -> Void)? { get set }
  func start()
  func stop()
}

/// One player host owns the output registration. Engines borrow it: quiesce the
/// current engine before activating its replacement, and dispose the output only
/// when the host itself is disposed. Session callback authority stays with the host.
struct YlPlatformServices {
  let platform: YlApplePlatform
  let textureOutput: any YlTextureOutput
  let makeDisplayDriver: (@escaping () -> Void) -> any YlDisplayDriving
  let activateAudioSession: () throws -> Void
  var nativeViewType: String?
  var beforeAudioOutput: () throws -> Void = {}
  var externalAudioRouteIdentity: () -> String? = { nil }
  var mediaDeliveryService: () throws -> any YlMediaDeliveryService = { throw YlMediaDeliveryRegistry.unavailable() }

  init(platform: YlApplePlatform, textureOutput: any YlTextureOutput,
       makeDisplayDriver: @escaping (@escaping () -> Void) -> any YlDisplayDriving,
       activateAudioSession: @escaping () throws -> Void = {}) {
    self.platform = platform
    self.textureOutput = textureOutput
    self.nativeViewType = (textureOutput as? YlNativeVideoSurfaceOutput)?.nativeViewType
    self.makeDisplayDriver = makeDisplayDriver
    self.activateAudioSession = activateAudioSession
  }
  var compatibility: YlAppleCompatibility { .init(platform: platform) }
}

extension YlPlatformServices {
  func borrowing(_ output: any YlTextureOutput) -> Self {
    var result = Self(platform: platform, textureOutput: output,
      makeDisplayDriver: makeDisplayDriver, activateAudioSession: activateAudioSession)
    result.beforeAudioOutput = beforeAudioOutput
    result.externalAudioRouteIdentity = externalAudioRouteIdentity
    result.mediaDeliveryService = mediaDeliveryService
    result.nativeViewType = nativeViewType
    return result
  }
}

/// Host ownership is independent from an engine's retained output resources.
/// Each candidate borrows a private lease; only the committed lease can publish.
final class YlAppleTextureOwner {
  fileprivate var supportsTimedVideo: Bool { (output as? YlTimedVideoOutput)?.supportsTimedVideo ?? false }
  private let output: any YlTextureOutput
  private var current: YlAppleTextureLease?
  private let leases = NSHashTable<YlAppleTextureLease>.weakObjects()
  private var disposed = false
  private let onFrame: (YlAppleSessionIdentity) -> Void
  private let timedLock = NSLock()
  private var timedEpoch: UInt64 = 0
  private var creatingTimedEndpoint = false
  private var retiringTimedEndpoint: YlTimedVideoLeaseEndpoint?
  init(output: any YlTextureOutput, onFailure: ((YlAppleSessionIdentity, NativePlayerError) -> Void)? = nil, onFrame: @escaping (YlAppleSessionIdentity) -> Void) {
    self.output = output
    self.onFrame = onFrame
    (output as? YlNativeVideoSurfaceOutput)?.onRenderFailure = { [weak self] error in
      guard let self, !self.disposed, let current = self.current, !current.invalidated else { return }
      onFailure?(current.identity, error)
    }
  }
  var textureId: Int64 { output.textureId }
  func makeLease(identity: YlAppleSessionIdentity) -> YlAppleTextureLease {
    let lease = YlAppleTextureLease(owner: self, identity: identity)
    lease.invalidated = disposed
    leases.add(lease)
    return lease
  }
  func commit(_ lease: YlAppleTextureLease) {
    guard !disposed, !lease.invalidated else { return }
    if let current, current !== lease {
      retireTimedEndpoint(current)
      current.pendingFrame = nil
      current.invalidated = true
      if (output as? YlNativeVideoSurfaceOutput)?.nativeViewType != nil { output.clear() }
    }
    current = lease
    if let pending = lease.pendingFrame {
      publish(pending.pixelBuffer, retaining: pending.reservation, from: lease)
    }
    lease.pendingFrame = nil
  }
  fileprivate func publish(_ frame: CVPixelBuffer?, retaining reservation: AnyObject?, from lease: YlAppleTextureLease) {
    guard !disposed, !lease.invalidated else { return }
    guard current === lease else {
      lease.pendingFrame = frame.map { (pixelBuffer: $0, reservation: reservation) }
      return
    }
    guard let frame else { return }
    ylPublishVideoFrame(frame, retaining: reservation, to: output)
    onFrame(lease.identity)
  }
  fileprivate func makeTimedEndpoint(_ lease: YlAppleTextureLease) -> (any YlTimedVideoEndpoint)? {
    guard !disposed, !lease.invalidated, current === lease else { return nil }
    timedLock.lock()
    if let existing = lease.timedEndpoint {
      timedLock.unlock()
      if existing.isRetired { retireTimedEndpoint(lease); return nil }
      return existing
    }
    guard retiringTimedEndpoint == nil, !creatingTimedEndpoint else { timedLock.unlock(); return nil }
    creatingTimedEndpoint = true
    let epoch = timedEpoch
    timedLock.unlock()
    let endpoint = (output as? YlTimedVideoOutput)?.makeTimedVideoEndpoint().map { native in
      YlTimedVideoLeaseEndpoint(native, onFirstEnqueue: { [weak self, weak lease] in
        let deliver = { [weak self, weak lease] in
          guard let self, let lease, !self.disposed, !lease.invalidated, self.current === lease else { return }
          self.onFrame(lease.identity)
        }
        if Thread.isMainThread { deliver() } else { DispatchQueue.main.async(execute: deliver) }
      })
    }
    timedLock.lock()
    creatingTimedEndpoint = false
    let valid = timedEpoch == epoch && !disposed && !lease.invalidated && current === lease
    if valid { lease.timedEndpoint = endpoint }
    else if let endpoint { retiringTimedEndpoint = endpoint }
    timedLock.unlock()
    if !valid, let endpoint { finishTimedRetirement(endpoint) }
    return valid ? endpoint : nil
  }
  private func retireTimedEndpoint(_ lease: YlAppleTextureLease) {
    let endpoint = timedLock.withLock { () -> YlTimedVideoLeaseEndpoint? in
      timedEpoch &+= 1
      let endpoint = lease.timedEndpoint
      lease.timedEndpoint = nil
      if let endpoint { retiringTimedEndpoint = endpoint }
      return endpoint
    }
    if let endpoint { finishTimedRetirement(endpoint) }
  }
  private func finishTimedRetirement(_ endpoint: YlTimedVideoLeaseEndpoint) {
    endpoint.retire(removingImage: true) { [weak self, weak endpoint] in
      guard let self, let endpoint else { return }
      self.timedLock.withLock {
        if self.retiringTimedEndpoint === endpoint { self.retiringTimedEndpoint = nil }
      }
    }
  }
  fileprivate func clear(_ lease: YlAppleTextureLease) {
    retireTimedEndpoint(lease)
    lease.pendingFrame = nil
    if current === lease, !disposed { output.clear() }
  }
  private func invalidateLeases() {
    for lease in leases.allObjects {
      retireTimedEndpoint(lease)
      lease.pendingFrame = nil
      lease.invalidated = true
    }
    leases.removeAllObjects()
    current = nil
  }
  func stop() {
    invalidateLeases()
    if !disposed { output.clear() }
  }
  func dispose() {
    guard !disposed else { return }
    disposed = true
    invalidateLeases()
    output.dispose()
  }
}

final class YlAppleTextureLease: YlRetainedVideoOutput, YlTimedVideoOutput {
  fileprivate weak var owner: YlAppleTextureOwner?
  let identity: YlAppleSessionIdentity
  fileprivate var pendingFrame: (pixelBuffer: CVPixelBuffer, reservation: AnyObject?)?
  fileprivate var invalidated = false
  fileprivate var timedEndpoint: YlTimedVideoLeaseEndpoint?
  fileprivate init(owner: YlAppleTextureOwner, identity: YlAppleSessionIdentity) {
    self.owner = owner
    self.identity = identity
  }
  var textureId: Int64 { owner?.textureId ?? -1 }
  func publish(_ pixelBuffer: CVPixelBuffer?) { owner?.publish(pixelBuffer, retaining: nil, from: self) }
  func publish(_ pixelBuffer: CVPixelBuffer, retaining reservation: AnyObject?) {
    owner?.publish(pixelBuffer, retaining: reservation, from: self)
  }
  var supportsTimedVideo: Bool { owner?.supportsTimedVideo ?? false }
  func makeTimedVideoEndpoint() -> (any YlTimedVideoEndpoint)? { owner?.makeTimedEndpoint(self) }
  func resize(width: Int, height: Int) {}
  func clear() { owner?.clear(self) }
  func dispose() { clear(); invalidated = true }
}

/// The retained AVPlayer changes item authority without reallocating its texture.
final class YlAppleAvTextureBinding: YlRetainedVideoOutput {
  var lease: YlAppleTextureLease?
  let textureId: Int64
  init(textureId: Int64) { self.textureId = textureId }
  func publish(_ pixelBuffer: CVPixelBuffer?) { lease?.publish(pixelBuffer) }
  func publish(_ pixelBuffer: CVPixelBuffer, retaining reservation: AnyObject?) {
    lease?.publish(pixelBuffer, retaining: reservation)
  }
  func resize(width: Int, height: Int) { lease?.resize(width: width, height: height) }
  func clear() { lease?.clear() }
  func dispose() { lease?.dispose(); lease = nil }
}
