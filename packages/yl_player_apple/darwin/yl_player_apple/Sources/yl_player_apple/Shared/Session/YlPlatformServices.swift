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
  var usesBackpressure: Bool { platform == .macos }
  var preservesLiveResumeIntent: Bool { platform == .macos }
  var audioDurationUs: Int64 { platform == .ios ? 500_000 : 1_000_000 }
  var scalesAudioDuration: Bool { platform == .macos }
  var batchesAudioInput: Bool { platform == .macos }
  var usesInterleavedPCM: Bool { platform == .ios }
  var limitsVideoReservations: Bool { platform == .macos }
  var retainsReplacementHls: Bool { platform == .ios }
  var reconnectsAvPlayer: Bool { platform == .ios }
}

protocol YlTextureOutput: AnyObject {
  var textureId: Int64 { get }
  func publish(_ pixelBuffer: CVPixelBuffer?)
  func resize(width: Int, height: Int)
  func clear()
  func dispose()
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
  var beforeAudioOutput: () throws -> Void = {}

  init(platform: YlApplePlatform, textureOutput: any YlTextureOutput,
       makeDisplayDriver: @escaping (@escaping () -> Void) -> any YlDisplayDriving,
       activateAudioSession: @escaping () throws -> Void = {}) {
    self.platform = platform
    self.textureOutput = textureOutput
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
    return result
  }
}

/// Host ownership is independent from an engine's retained output resources.
/// Each candidate borrows a private lease; only the committed lease can publish.
final class YlAppleTextureOwner {
  private let output: any YlTextureOutput
  private var current: YlAppleTextureLease?
  private var disposed = false
  private let onFrame: (YlAppleSessionIdentity) -> Void
  init(output: any YlTextureOutput, onFrame: @escaping (YlAppleSessionIdentity) -> Void) {
    self.output = output
    self.onFrame = onFrame
  }
  var textureId: Int64 { output.textureId }
  func makeLease(identity: YlAppleSessionIdentity) -> YlAppleTextureLease {
    YlAppleTextureLease(owner: self, identity: identity)
  }
  func commit(_ lease: YlAppleTextureLease) {
    guard !disposed, !lease.invalidated else { return }
    current = lease
    if let pending = lease.pendingFrame { publish(pending, from: lease) }
    lease.pendingFrame = nil
  }
  fileprivate func publish(_ frame: CVPixelBuffer?, from lease: YlAppleTextureLease) {
    guard !disposed, !lease.invalidated else { return }
    guard current === lease else { lease.pendingFrame = frame; return }
    guard let frame else { return }
    output.publish(frame)
    onFrame(lease.identity)
  }
  fileprivate func clear(_ lease: YlAppleTextureLease) {
    lease.pendingFrame = nil
    if current === lease, !disposed { output.clear() }
  }
  func stop() {
    current?.pendingFrame = nil
    current = nil
    if !disposed { output.clear() }
  }
  func dispose() {
    guard !disposed else { return }
    disposed = true
    current?.pendingFrame = nil
    current = nil
    output.dispose()
  }
}

final class YlAppleTextureLease: YlTextureOutput {
  fileprivate weak var owner: YlAppleTextureOwner?
  let identity: YlAppleSessionIdentity
  fileprivate var pendingFrame: CVPixelBuffer?
  fileprivate var invalidated = false
  fileprivate init(owner: YlAppleTextureOwner, identity: YlAppleSessionIdentity) {
    self.owner = owner
    self.identity = identity
  }
  var textureId: Int64 { owner?.textureId ?? -1 }
  func publish(_ pixelBuffer: CVPixelBuffer?) { owner?.publish(pixelBuffer, from: self) }
  func resize(width: Int, height: Int) {}
  func clear() { owner?.clear(self) }
  func dispose() { clear(); invalidated = true }
}

/// The retained AVPlayer changes item authority without reallocating its texture.
final class YlAppleAvTextureBinding: YlTextureOutput {
  var lease: YlAppleTextureLease?
  let textureId: Int64
  init(textureId: Int64) { self.textureId = textureId }
  func publish(_ pixelBuffer: CVPixelBuffer?) { lease?.publish(pixelBuffer) }
  func resize(width: Int, height: Int) { lease?.resize(width: width, height: height) }
  func clear() { lease?.clear() }
  func dispose() { lease?.dispose(); lease = nil }
}
