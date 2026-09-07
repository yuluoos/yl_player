/// The Dart platform contract major; independent of native transport versions.
const ylPlayerSpiMajor = 2;

/// Runtime implementation identity used by the controller's SPI handshake.
final class YlPlatformImplementationInfo {
  const YlPlatformImplementationInfo({
    required this.name,
    required this.version,
    required this.spiMajor,
  });
  final String name;
  final String version;
  final int spiMajor;
  @override
  bool operator ==(Object other) =>
      other is YlPlatformImplementationInfo &&
      name == other.name &&
      version == other.version &&
      spiMajor == other.spiMajor;
  @override
  int get hashCode => Object.hash(name, version, spiMajor);
  @override
  String toString() =>
      'YlPlatformImplementationInfo(name: <redacted>, version: <redacted>, spiMajor: $spiMajor)';
}
