#if os(iOS)
import UIKit
import Flutter
import AVFoundation
import CoreVideo

/// Native Flutter registry ownership; no media processing occurs at this boundary.
final class YlIosTextureOutput: NSObject, FlutterTexture, YlTextureOutput {
  private let textures: FlutterTextureRegistry
  private let lock = NSLock()
  private var pixelBuffer: CVPixelBuffer?
  private(set) var textureId: Int64

  init(textures: FlutterTextureRegistry, textureId: Int64? = nil) {
    self.textures = textures
    self.textureId = textureId ?? -1
    super.init()
    if textureId == nil { self.textureId = textures.register(self) }
  }
  func publish(_ pixelBuffer: CVPixelBuffer?) {
    lock.lock()
    guard textureId >= 0 else { lock.unlock(); return }
    self.pixelBuffer = pixelBuffer
    let identity = textureId
    lock.unlock()
    textures.textureFrameAvailable(identity)
  }
  func resize(width: Int, height: Int) {
    // Pixel-buffer dimensions carry texture size; Flutter has no resize call.
  }
  func clear() {
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
    if identity >= 0 { textures.unregisterTexture(identity) }
  }
}
#endif
