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
