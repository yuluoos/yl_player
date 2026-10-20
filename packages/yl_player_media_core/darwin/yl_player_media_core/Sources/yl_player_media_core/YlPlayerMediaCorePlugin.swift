#if os(iOS) && canImport(Flutter)
import Flutter
#elseif os(macOS) && canImport(FlutterMacOS)
import FlutterMacOS
#endif

#if canImport(Flutter) || canImport(FlutterMacOS)
public final class YlPlayerMediaCorePlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {}
}
#endif
