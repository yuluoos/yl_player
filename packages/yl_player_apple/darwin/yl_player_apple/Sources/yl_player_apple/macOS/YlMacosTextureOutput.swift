import yl_player_media_core
#if os(macOS)
import AppKit
import FlutterMacOS
import AVFoundation
import CoreVideo

/// Native Flutter registry ownership; no media processing occurs at this boundary.
final class YlMacosTextureOutput: NSObject, FlutterTexture, YlTextureOutput, YlNativeVideoSurfaceOutput, YlRetainedVideoOutput, YlTimedVideoOutput {
  private let nativeViews: YlMacosVideoViewFactory?
  private let mailbox = YlVideoSurfaceMailbox()
  private let renderer = YlSampleBufferVideoRenderer()
  private weak var attachedContainer: CALayer?
  private let timedLock = NSLock()
  private var lastTimedLifetimeDiagnostics: AnyObject?
  var collectTimedDiagnostics = false // Internal opt-in observation; no public setting.
  var timedDiagnostics: [String: Any]? {
    guard #available(macOS 14.0, *) else { return nil }
    let state = timedLock.withLock { (timedEndpoint, lastTimedLifetimeDiagnostics) }
    return (state.0 as? YlMacosTimedVideoEndpoint)?.diagnostics
      ?? (state.1 as? YlTimedVideoLifetimeDiagnostics).map { ["lifetime": $0.snapshot] }
  }
  private var timedEndpoint: (any YlTimedVideoEndpoint)?
  private var timedRetiring = false
  private var timedEpoch: UInt64 = 0
  private var hasActiveTimedEndpoint: Bool {
    let endpoint = timedLock.withLock { timedEndpoint }
    return endpoint.map { !$0.isRetired } ?? false
  }
  #if DEBUG && YL_BOUND_AV
  /// Read only the layer attached by this output's real Flutter platform view.
  func boundDisplayedPixelBuffer() -> CVPixelBuffer? {
    guard Thread.isMainThread, textureId >= 0 else { return nil }
    return YlBoundFlutterProbe.displayedPixel(in: attachedContainer)
  }
  #endif
  var nativeViewType: String? { nativeViews == nil ? nil : YlMacosVideoViewFactory.viewType }
  var onRenderFailure: ((NativePlayerError) -> Void)?
  func attach(_ layer: CALayer) {
    guard textureId >= 0 else { return }
    retireTimedEndpoint(preservingPausedPreview: true)
    attachedContainer = layer
    renderer.attach(layer)
  }
  func layoutVideoSurface() {
    if #available(macOS 14.0, *), let container = attachedContainer,
       let endpoint = timedLock.withLock({ timedEndpoint }) as? YlMacosTimedVideoEndpoint {
      endpoint.layout(in: container)
    }
    renderer.layout()
  }
  func detach(_ layer: CALayer) {
    if attachedContainer === layer { retireTimedEndpoint(preservingPausedPreview: true); attachedContainer = nil }
    renderer.detach(layer)
  }

  var supportsTimedVideo: Bool {
    if #available(macOS 14.0, *) { return nativeViews != nil }
    return false
  }

  func makeTimedVideoEndpoint() -> (any YlTimedVideoEndpoint)? {
    precondition(Thread.isMainThread)
    guard #available(macOS 14.0, *), nativeViews != nil, textureId >= 0,
          let container = attachedContainer else { return nil }
    let epoch = timedLock.withLock { () -> UInt64? in
      guard timedEndpoint == nil, !timedRetiring else { return nil }
      timedEpoch &+= 1; return timedEpoch
    }
    guard let epoch else { return nil }
    renderer.detach(container)
    do {
      let endpoint = try YlMacosTimedVideoEndpoint(container: container, collectDiagnostics: collectTimedDiagnostics) { [weak self] error in
        guard let self, self.timedLock.withLock({ self.timedEpoch == epoch }) else { return }
        let native = error as NSError
        self.onRenderFailure?(NativePlayerError(category: "render", code: "render.video_surface_failed",
          message: "The native video surface could not display the frame.",
          diagnostic: "timed AVSampleBufferVideoRenderer domain=\(native.domain) code=\(native.code)"))
      }
      timedLock.withLock { timedEndpoint = endpoint; lastTimedLifetimeDiagnostics = endpoint.lifetimeDiagnostics }
      return endpoint
    } catch {
      renderer.attach(container)
      let native = error as NSError
      onRenderFailure?(NativePlayerError(category: "render", code: "render.video_surface_failed",
        message: "The native video timeline could not be created.",
        diagnostic: "CMTimebase setup domain=\(native.domain) code=\(native.code)"))
      return nil
    }
  }

  private func retireTimedEndpoint(preservingPausedPreview: Bool = false) {
    let endpoint = timedLock.withLock { () -> (any YlTimedVideoEndpoint)? in
      timedEpoch &+= 1
      guard !timedRetiring, let timedEndpoint else { return nil }
      timedRetiring = true
      return timedEndpoint
    }
    guard let endpoint else { return }
    if preservingPausedPreview, #available(macOS 14.0, *),
       let frame = (endpoint as? YlMacosTimedVideoEndpoint)?.pausedPreview {
      precondition(Thread.isMainThread)
      renderer.publish(unsafeBitCast(frame.payload, to: CVPixelBuffer.self), retaining: frame.reservation)
    }
    endpoint.retire(removingImage: true) { [weak self] in
      guard let self else { return }
      self.timedLock.withLock {
        if self.timedEndpoint === endpoint { self.timedEndpoint = nil; self.timedRetiring = false }
      }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.textureId >= 0, let container = self.attachedContainer,
              self.timedLock.withLock({ self.timedEndpoint == nil }) else { return }
        self.renderer.attach(container)
      }
    }
  }
  private let textures: FlutterTextureRegistry
  private let lock = NSLock()
  private var pixelBuffer: CVPixelBuffer?
  private(set) var textureId: Int64

  init(textures: FlutterTextureRegistry, textureId: Int64? = nil, nativeViews: YlMacosVideoViewFactory? = nil) {
    self.nativeViews = nativeViews
    self.textures = textures
    self.textureId = textureId ?? -1
    super.init()
    if textureId == nil { self.textureId = textures.register(self) }
    nativeViews?.register(self)
    mailbox.consume = { [weak self] frame, clear, disposed, epoch in
      guard let self else { return }
      if disposed { self.renderer.dispose(); return }
      guard self.mailbox.accepts(epoch) else { return }
      self.renderer.onFailure = { [weak self] error in
        guard let self, self.mailbox.accepts(epoch) else { return }
        let native = error as NSError
        self.onRenderFailure?(NativePlayerError(category: "render", code: "render.video_surface_failed",
          message: "The native video surface could not display the frame.",
          diagnostic: "AVSampleBufferDisplayLayer domain=\(native.domain) code=\(native.code)"))
      }
      if clear { self.renderer.clear() }
      if let frame, !self.hasActiveTimedEndpoint { self.renderer.publish(frame.pixelBuffer, retaining: frame.reservation) }
    }
  }
  func publish(_ pixelBuffer: CVPixelBuffer?) {
    if nativeViews != nil {
      if let pixelBuffer { publish(pixelBuffer, retaining: nil) } else { mailbox.clear() }
      return
    }
    lock.lock()
    guard textureId >= 0 else { lock.unlock(); return }
    self.pixelBuffer = pixelBuffer
    let identity = textureId
    lock.unlock()
    textures.textureFrameAvailable(identity)
  }
  func publish(_ pixelBuffer: CVPixelBuffer, retaining reservation: AnyObject?) {
    guard nativeViews != nil else { publish(pixelBuffer); return }
    mailbox.publish(.init(pixelBuffer: pixelBuffer, reservation: reservation))
  }
  func resize(width: Int, height: Int) {
    // Pixel-buffer dimensions carry texture size; Flutter has no resize call.
  }
  func clear() {
    retireTimedEndpoint()
    mailbox.clear()
    lock.lock()
    pixelBuffer = nil
    lock.unlock()
  }
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    return pixelBuffer.map { Unmanaged.passRetained($0) }
  }
  func dispose() {
    lock.lock()
    let identity = textureId
    textureId = -1
    pixelBuffer = nil
    lock.unlock()
    retireTimedEndpoint()
    mailbox.dispose()
    DispatchQueue.main.async { [renderer] in renderer.dispose() }
    onRenderFailure = nil
    if Thread.isMainThread { nativeViews?.unregister(identity) }
    else { DispatchQueue.main.async { [nativeViews] in nativeViews?.unregister(identity) } }
    if identity >= 0 { textures.unregisterTexture(identity) }
  }
}
#endif
