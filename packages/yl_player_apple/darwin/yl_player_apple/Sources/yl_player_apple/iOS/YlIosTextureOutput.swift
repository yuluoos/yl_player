#if os(iOS)
import UIKit
import Flutter
import AVFoundation
import CoreVideo

/// Native Flutter registry ownership; no media processing occurs at this boundary.
final class YlIosTextureOutput: NSObject, FlutterTexture, YlTextureOutput, YlNativeVideoSurfaceOutput, YlRetainedVideoOutput {
  private let nativeViews: YlIosVideoViewFactory?
  private let mailbox = YlVideoSurfaceMailbox()
  private let renderer = YlSampleBufferVideoRenderer()
  #if DEBUG && YL_BOUND_AV
  private weak var attachedContainer: CALayer?
  #endif
  #if DEBUG && YL_BOUND_AV
  /// Read only the layer attached by this output's real Flutter platform view.
  func boundDisplayedPixelBuffer() -> CVPixelBuffer? {
    guard Thread.isMainThread, textureId >= 0 else { return nil }
    return YlBoundFlutterProbe.displayedPixel(in: attachedContainer)
  }
  #endif
  var nativeViewType: String? { nativeViews == nil ? nil : YlIosVideoViewFactory.viewType }
  var onRenderFailure: ((NativePlayerError) -> Void)?
  func attach(_ layer: CALayer) {
    guard textureId >= 0 else { return }
    #if DEBUG && YL_BOUND_AV
    attachedContainer = layer
    #endif
    renderer.attach(layer)
  }
  func layoutVideoSurface() { renderer.layout() }
  func detach(_ layer: CALayer) {
    #if DEBUG && YL_BOUND_AV
    if attachedContainer === layer { attachedContainer = nil }
    #endif
    renderer.detach(layer)
  }
  private let textures: FlutterTextureRegistry
  private let lock = NSLock()
  private var pixelBuffer: CVPixelBuffer?
  private(set) var textureId: Int64

  init(textures: FlutterTextureRegistry, textureId: Int64? = nil, nativeViews: YlIosVideoViewFactory? = nil) {
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
      if let frame { self.renderer.publish(frame.pixelBuffer, retaining: frame.reservation) }
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
    mailbox.dispose()
    DispatchQueue.main.async { [renderer] in renderer.dispose() }
    onRenderFailure = nil
    if Thread.isMainThread { nativeViews?.unregister(identity) }
    else { DispatchQueue.main.async { [nativeViews] in nativeViews?.unregister(identity) } }
    if identity >= 0 { textures.unregisterTexture(identity) }
  }
}
#endif
