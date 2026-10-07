#if os(iOS)
import Flutter
import UIKit
#elseif os(macOS)
import Cocoa
import FlutterMacOS
#endif

public final class YlPlayerApplePlugin: NSObject, FlutterPlugin {
  private let registry: YlApplePlayerRegistry
  private let hostMessenger: FlutterBinaryMessenger
  private init(registry: YlApplePlayerRegistry, hostMessenger: FlutterBinaryMessenger) {
    self.registry = registry
    self.hostMessenger = hostMessenger
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    let hostMessenger = messenger
    let lifecycle = YlIosLifecycle()
    let nativeViews = YlIosVideoViewFactory()
    registrar.register(nativeViews, withId: YlIosVideoViewFactory.viewType)
    let services: (ApplePlayerOptionsMessage) throws -> YlPlatformServices = { [weak registrar] _ in
      guard let registrar else { throw YlAppleFailureMapper.invalid("player.detached") }
      // appManaged must not mutate application-owned AVAudioSession state.
      return YlIosPlatformAdapter.makeServices(textures: registrar.textures(), activateAudioSession: {}, nativeViews: nativeViews)
    }
    #else
    let messenger = registrar.messenger
    let hostMessenger = YlMacosHostMessenger(messenger)
    let lifecycle = YlMacosLifecycle()
    let nativeViews = YlMacosVideoViewFactory()
    registrar.register(nativeViews, withId: YlMacosVideoViewFactory.viewType)
    let services: (ApplePlayerOptionsMessage) throws -> YlPlatformServices = { [weak registrar] _ in
      guard let registrar else { throw YlAppleFailureMapper.invalid("player.detached") }
      return YlMacosPlatformAdapter.makeServices(textures: registrar.textures,
        displayView: registrar.view, activateAudioSession: {}, nativeViews: nativeViews)
    }
    #endif
    let protectedViews = YlFairPlayViewRegistry()
    registrar.register(YlFairPlayViewFactory(registry: protectedViews), withId: YlFairPlayViewFactory.viewType)
    let registry = YlApplePlayerRegistry(makeServices: services,
      makeCallbacks: { makeCallbacks(messenger: messenger, suffix: $0) },
      installHost: { suffix, host in
        ApplePlayerHostApiSetup.setUp(binaryMessenger: hostMessenger, api: host, messageChannelSuffix: suffix)
      }, lifecycle: lifecycle, makeDrmBridge: { id, suffix in
        let bridge = YlFairPlayBridge(playerId: id, views: protectedViews,
          callbacks: AppleDrmFlutterApi(binaryMessenger: YlApplePlatformMessenger(messenger), messageChannelSuffix: suffix))
        AppleDrmHostApiSetup.setUp(binaryMessenger: hostMessenger, api: bridge, messageChannelSuffix: suffix)
        return bridge
      }, uninstallDrm: { suffix in
        AppleDrmHostApiSetup.setUp(binaryMessenger: hostMessenger, api: nil, messageChannelSuffix: suffix)
      })
    ApplePlayerFactoryHostApiSetup.setUp(binaryMessenger: hostMessenger, api: registry)
    registrar.publish(YlPlayerApplePlugin(registry: registry, hostMessenger: hostMessenger))
  }

  static func makeCallbacks(messenger: FlutterBinaryMessenger, suffix: String) -> ApplePlayerFlutterApi {
    ApplePlayerFlutterApi(binaryMessenger: YlApplePlatformMessenger(messenger), messageChannelSuffix: suffix)
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    registry.detach()
    ApplePlayerFactoryHostApiSetup.setUp(binaryMessenger: hostMessenger, api: nil)
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
  // uses a separate messenger; this adapter does not manage host connections.
  func setMessageHandlerOnChannel(_ channel: String,
      binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    messenger.setMessageHandlerOnChannel(channel, binaryMessageHandler: handler)
  }

  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {
    messenger.cleanUpConnection(connection)
  }
}

#if os(macOS)
/// Generated setUp(api: nil) creates fresh channels without their original
/// connection IDs. macOS's nil-handler registration retains an engine record.
/// Keep IDs across setup calls so disposal removes only our own registrations.
/// These Pigeon host APIs use the platform thread and no background task queue.
private final class YlMacosHostMessenger: NSObject, FlutterBinaryMessenger {
  private let messenger: FlutterBinaryMessenger
  private var connections: [String: FlutterBinaryMessengerConnection] = [:]

  init(_ messenger: FlutterBinaryMessenger) { self.messenger = messenger }

  func send(onChannel channel: String, message: Data?) {
    messenger.send(onChannel: channel, message: message)
  }

  func send(onChannel channel: String, message: Data?, binaryReply: FlutterBinaryReply?) {
    messenger.send(onChannel: channel, message: message, binaryReply: binaryReply)
  }

  func setMessageHandlerOnChannel(_ channel: String,
      binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    if let handler {
      let connection = messenger.setMessageHandlerOnChannel(channel, binaryMessageHandler: handler)
      connections[channel] = connection
      return connection
    }
    if let connection = connections.removeValue(forKey: channel) {
      messenger.cleanUpConnection(connection)
    }
    return 0
  }

  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {
    connections = connections.filter { $0.value != connection }
    messenger.cleanUpConnection(connection)
  }
}
#endif
