import AVFoundation
import CoreMedia
import Foundation

/// displaySize is the clean-aperture sample size. The consumer applies PAR once,
/// then the transform still owed by the texture. Encoded size describes source.
struct YlVideoGeometry {
  let encodedSize: CGSize
  let cleanAperture: CGRect
  let displaySize: CGSize
  let pixelAspectRatio: Double
  let rotationDegrees: Int
  var finalDisplaySize: CGSize {
    let corrected = CGSize(width: displaySize.width * pixelAspectRatio,
                           height: displaySize.height)
    return rotationDegrees == 90 || rotationDegrees == 270
      ? CGSize(width: corrected.height, height: corrected.width) : corrected
  }
  var message: AppleVideoGeometryMessage {
    .init(encodedSize: .init(width: encodedSize.width, height: encodedSize.height),
      displaySize: .init(width: displaySize.width, height: displaySize.height),
      pixelAspectRatio: pixelAspectRatio, rotationDegrees: Int64(rotationDegrees))
  }
}

enum YlVideoGeometryResolver {
  static func avPlayer(pixelBuffer: CVPixelBuffer, rotationDegrees: Int = 0) -> YlVideoGeometry? {
    // HLS may expose no AVAssetTrack even while video output is delivering
    // frames. Read measured frame dimensions/aperture/PAR without asset I/O.
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
      let format else { return nil }
    return managed(format: format, rotationDegrees: rotationDegrees)
  }

  static func resolve(encodedSize: CGSize, cleanAperture: CGRect?, pixelAspectRatio: Double,
                      rotationDegrees: Int, pixelsAreOriented: Bool = false) -> YlVideoGeometry? {
    guard valid(encodedSize), pixelAspectRatio.isFinite, pixelAspectRatio > 0,
          rotationDegrees % 90 == 0 else { return nil }
    let aperture = cleanAperture ?? CGRect(origin: .zero, size: encodedSize)
    guard valid(aperture.size), aperture.origin.x.isFinite, aperture.origin.y.isFinite,
          aperture.minX >= 0, aperture.minY >= 0,
          aperture.maxX <= encodedSize.width, aperture.maxY <= encodedSize.height else { return nil }
    let rotation = (rotationDegrees % 360 + 360) % 360
    var display = aperture.size
    var reportedPAR = pixelAspectRatio
    if pixelsAreOriented {
      // After native orientation the original horizontal PAR axis may be
      // vertical. Bake its effective logical size and report square pixels so
      // the wire consumer neither applies PAR on the wrong axis nor rotates.
      display.width *= pixelAspectRatio
      if rotation == 90 || rotation == 270 {
        display = CGSize(width: display.height, height: display.width)
      }
      reportedPAR = 1
    }
    guard valid(display) else { return nil }
    return .init(encodedSize: encodedSize, cleanAperture: aperture, displaySize: display,
      pixelAspectRatio: reportedPAR, rotationDegrees: pixelsAreOriented ? 0 : rotation)
  }

  static func managed(format: CMVideoFormatDescription, rotationDegrees: Int = 0,
                      pixelsAreOriented: Bool = false) -> YlVideoGeometry? {
    let dimensions = CMVideoFormatDescriptionGetDimensions(format)
    let encoded = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
    let aperture = CMVideoFormatDescriptionGetCleanAperture(format, originIsAtTopLeft: true)
    var par = 1.0
    if let raw = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_PixelAspectRatio) {
      guard let values = raw as? [String: Any],
            let horizontal = values[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing as String] as? NSNumber,
            let vertical = values[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing as String] as? NSNumber,
            horizontal.doubleValue > 0, vertical.doubleValue > 0 else { return nil }
      par = horizontal.doubleValue / vertical.doubleValue
    }
    return resolve(encodedSize: encoded, cleanAperture: aperture, pixelAspectRatio: par,
      rotationDegrees: rotationDegrees, pixelsAreOriented: pixelsAreOriented)
  }

  static func avPlayer(presentationSize: CGSize, naturalSize: CGSize,
                       preferredTransform: CGAffineTransform, format: CMVideoFormatDescription?,
                       pixelsAreOriented: Bool = false) -> YlVideoGeometry? {
    // Only proper orthogonal rotations can be represented by this wire contract.
    let t = preferredTransform
    guard [t.a, t.b, t.c, t.d, t.tx, t.ty].allSatisfy({ $0.isFinite }),
          abs(t.a * t.d - t.b * t.c - 1) < 0.001 else { return nil }
    let degrees = atan2(t.b, t.a) * 180 / .pi
    let rotation = Int((degrees / 90).rounded()) * 90
    let expected = CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180)
    guard abs(t.a - expected.a) < 0.001, abs(t.b - expected.b) < 0.001,
          abs(t.c - expected.c) < 0.001, abs(t.d - expected.d) < 0.001 else { return nil }
    if let format { return managed(format: format, rotationDegrees: rotation, pixelsAreOriented: pixelsAreOriented) }
    // A valid naturalSize supplies the encoded fallback. presentationSize alone
    // cannot establish encoded dimensions; use it only for the display measure.
    guard valid(naturalSize) else { return nil }
    let base = resolve(encodedSize: naturalSize, cleanAperture: nil, pixelAspectRatio: 1,
      rotationDegrees: rotation, pixelsAreOriented: pixelsAreOriented)
    guard let base, valid(presentationSize) else { return base }
    let display = !pixelsAreOriented && (base.rotationDegrees == 90 || base.rotationDegrees == 270)
      ? CGSize(width: presentationSize.height, height: presentationSize.width) : presentationSize
    return .init(encodedSize: base.encodedSize, cleanAperture: base.cleanAperture,
      displaySize: display, pixelAspectRatio: base.pixelAspectRatio, rotationDegrees: base.rotationDegrees)
  }

  static func avPlayer(item: AVPlayerItem?) -> YlVideoGeometry? {
    guard let item, let track = item.asset.tracks(withMediaType: .video).first else { return nil }
    let format = track.formatDescriptions.first.map { $0 as! CMVideoFormatDescription }
    // This backend publishes raw AVPlayerItemVideoOutput pixels and installs no
    // video composition; the track transform remains owed by the texture view.
    return avPlayer(presentationSize: item.presentationSize, naturalSize: track.naturalSize,
      preferredTransform: track.preferredTransform, format: format)
  }
  private static func valid(_ size: CGSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
  }
}
