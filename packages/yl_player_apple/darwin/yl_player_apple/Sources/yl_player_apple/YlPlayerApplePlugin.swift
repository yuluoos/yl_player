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
      makeCallbacks: { makeCallbacks(messenger: messenger, suffix: $0) },
      installHost: { suffix, host in
        ApplePlayerHostApiSetup.setUp(binaryMessenger: messenger, api: host, messageChannelSuffix: suffix)
      }, lifecycle: lifecycle)
    ApplePlayerFactoryHostApiSetup.setUp(binaryMessenger: messenger, api: registry)
    registrar.publish(YlPlayerApplePlugin(registry: registry))
  }

  static func makeCallbacks(messenger: FlutterBinaryMessenger, suffix: String) -> ApplePlayerFlutterApi {
    ApplePlayerFlutterApi(binaryMessenger: YlApplePlatformMessenger(messenger), messageChannelSuffix: suffix)
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

/// Pigeon's nonisolated async FlutterApi methods can leave MainActor before
/// reaching send(onChannel:). Marshal at the binary boundary, after encoding,
/// so every callback uses Flutter's platform thread without editing generated code.
/// The host's acknowledged FIFO continues to control ordering and backpressure.
private final class YlApplePlatformMessenger: NSObject, FlutterBinaryMessenger {
  private let messenger: FlutterBinaryMessenger
  init(_ messenger: FlutterBinaryMessenger) { self.messenger = messenger }

  func send(onChannel channel: String, message: Data?) {
    onPlatformThread { [messenger] in
      messenger.send(onChannel: channel, message: message)
    }
  }

  func send(onChannel channel: String, message: Data?, binaryReply: FlutterBinaryReply?) {
    onPlatformThread { [messenger] in
      messenger.send(onChannel: channel, message: message, binaryReply: binaryReply)
    }
  }

  private func onPlatformThread(_ send: @escaping () -> Void) {
    if Thread.isMainThread { send() }
    else { DispatchQueue.main.async(execute: send) }
  }

  // Only outbound FlutterApi channels use this adapter. Host channel registration
  // still uses the registrar's original messenger and its existing task queues.
  func setMessageHandlerOnChannel(_ channel: String,
      binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    messenger.setMessageHandlerOnChannel(channel, binaryMessageHandler: handler)
  }

  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {
    messenger.cleanUpConnection(connection)
  }
}
