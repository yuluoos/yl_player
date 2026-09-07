import 'value_helpers.dart';

/// Immutable VideoGeometry value; validate at publication boundaries.
final class YlVideoGeometry {
  const YlVideoGeometry({
    required this.encodedSize,
    required this.displaySize,
    this.pixelAspectRatio = 1,
    this.rotationDegrees = 0,
  });

  final YlPixelSize encodedSize;

  final YlPixelSize displaySize;

  final double pixelAspectRatio;

  final int rotationDegrees;

  /// Omitted fields are preserved; explicit null clears nullable fields.
  YlVideoGeometry copyWith({
    YlPixelSize? encodedSize,
    YlPixelSize? displaySize,
    double? pixelAspectRatio,
    int? rotationDegrees,
  }) => YlVideoGeometry(
    encodedSize: encodedSize ?? this.encodedSize,
    displaySize: displaySize ?? this.displaySize,
    pixelAspectRatio: pixelAspectRatio ?? this.pixelAspectRatio,
    rotationDegrees: rotationDegrees ?? this.rotationDegrees,
  );

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        encodedSize == other.encodedSize &&
        displaySize == other.displaySize &&
        pixelAspectRatio == other.pixelAspectRatio &&
        rotationDegrees == other.rotationDegrees,
  );

  @override
  int get hashCode => Object.hashAll([
    encodedSize,
    displaySize,
    pixelAspectRatio,
    rotationDegrees,
  ]);

  @override
  String toString() =>
      'YlVideoGeometry(encodedSize: $encodedSize, displaySize: $displaySize, pixelAspectRatio: $pixelAspectRatio, rotationDegrees: $rotationDegrees)';

  /// Uses clean aperture, pixel aspect ratio, and rotation still required by UI.
  double get displayAspectRatio {
    final ratio = displaySize.width * pixelAspectRatio / displaySize.height;
    return rotationDegrees == 90 || rotationDegrees == 270 ? 1 / ratio : ratio;
  }
}

/// Pixel dimensions are validated at native decode and state acceptance.
final class YlPixelSize {
  const YlPixelSize(this.width, this.height);
  final double width;
  final double height;
  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) => width == other.width && height == other.height,
  );
  @override
  int get hashCode => Object.hash(width, height);
  @override
  String toString() => 'YlPixelSize(width: $width, height: $height)';
}
