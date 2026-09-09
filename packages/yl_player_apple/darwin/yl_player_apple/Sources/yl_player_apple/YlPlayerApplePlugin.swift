#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif

public final class YlPlayerApplePlugin: NSObject, FlutterPlugin {
  private let registry: YlApplePlayerRegistry
  private init(registry: YlApplePlayerRegistry) { self.registry = registry; super.init() }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    let lifecycle = YlIosLifecycle()
    let services: (ApplePlayerOptionsMessage) throws -> YlPlatformServices = { [weak registrar] _ in
      guard let registrar else { throw YlAppleFailureMapper.invalid("player.detached") }
      // appManaged must not mutate application-owned AVAudioSession state.
      return YlIosPlatformAdapter.makeServices(textures: registrar.textures(), activateAudioSession: {})
    }
    #else
    let messenger = registrar.messenger
    let lifecycle = YlMacosLifecycle()
    let services: (ApplePlayerOptionsMessage) throws -> YlPlatformServices = { [weak registrar] _ in
      guard let registrar else { throw YlAppleFailureMapper.invalid("player.detached") }
      return YlMacosPlatformAdapter.makeServices(textures: registrar.textures,
        displayView: registrar.view, activateAudioSession: {})
    }
    #endif
    let registry = YlApplePlayerRegistry(makeServices: services,
      makeCallbacks: { ApplePlayerFlutterApi(binaryMessenger: messenger, messageChannelSuffix: $0) },
      installHost: { suffix, host in
        ApplePlayerHostApiSetup.setUp(binaryMessenger: messenger, api: host, messageChannelSuffix: suffix)
      }, lifecycle: lifecycle)
    ApplePlayerFactoryHostApiSetup.setUp(binaryMessenger: messenger, api: registry)
    registrar.publish(YlPlayerApplePlugin(registry: registry))
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    registry.detach()
    #if os(iOS)
    ApplePlayerFactoryHostApiSetup.setUp(binaryMessenger: registrar.messenger(), api: nil)
    #else
    ApplePlayerFactoryHostApiSetup.setUp(binaryMessenger: registrar.messenger, api: nil)
    #endif
  }
}
