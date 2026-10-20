import Foundation
import yl_player_media_core
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

public final class YlPlayerMediaDeliveryPlugin: NSObject, FlutterPlugin {
  private let messenger: FlutterBinaryMessenger
  private let engineIdentity: ObjectIdentifier
  private let factory: FlutterMethodChannel
  private var owners: [String: YlDeliveryOwner] = [:]
  private var closed = false

  init(messenger: FlutterBinaryMessenger) {
    engineIdentity = ObjectIdentifier(messenger as AnyObject)
    self.messenger = YlDeliveryMessenger(messenger)
    factory = FlutterMethodChannel(name: "dev.ylplayer.media_delivery", binaryMessenger: self.messenger)
    super.init()
    YlMediaDeliveryRegistry.install(YlMediaDeliveryEngine(), for: engineIdentity)
    factory.setMethodCallHandler { [weak self] call, reply in
      guard let self, !self.closed else { reply(Self.disposed()); return }
      guard call.method == "create" else { reply(FlutterMethodNotImplemented); return }
      let id = UUID().uuidString
      self.owners[id] = YlDeliveryOwner(id: id, messenger: self.messenger) { [weak self] in
        self?.owners.removeValue(forKey: id)
      }
      reply(id)
    }
  }
  public static func register(with registrar: FlutterPluginRegistrar) {
    #if os(iOS)
    let messenger = registrar.messenger()
    #else
    let messenger = registrar.messenger
    #endif
    registrar.publish(YlPlayerMediaDeliveryPlugin(messenger: messenger))
  }
  #if os(iOS)
  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    close()
  }
  #else
  /// Call on the platform thread before FlutterEngine.shutDownEngine().
  /// macOS has no FlutterPlugin detach callback and may retain published plugins
  /// after engine shutdown. Repeated calls are safe.
  @objc public func shutdown() {
    precondition(Thread.isMainThread, "Media delivery shutdown requires the platform thread.")
    close()
  }
  #endif
  private func close() {
    guard !closed else { return }
    closed = true
    factory.setMethodCallHandler(nil)
    let previous = owners
    owners.removeAll()
    for owner in previous.values { owner.close() }
    YlMediaDeliveryRegistry.remove(for: engineIdentity)
  }
  static func disposed() -> FlutterError {
    FlutterError(code: "player.disposed", message: "Media delivery is disposed.",
      details: ["category": "platform"])
  }
  deinit { close() }
}

private final class YlDeliveryOwner {
  private let channel: FlutterMethodChannel
  private let events: FlutterBasicMessageChannel
  private let session: any YlMediaDeliverySession
  private let released: () -> Void
  private var closed = false
  init(id: String, messenger: FlutterBinaryMessenger, released: @escaping () -> Void) {
    channel = FlutterMethodChannel(name: "dev.ylplayer.media_delivery.\(id)", binaryMessenger: messenger)
    events = FlutterBasicMessageChannel(name: "dev.ylplayer.media_delivery.events.\(id)",
      binaryMessenger: messenger, codec: FlutterStandardMessageCodec.sharedInstance())
    session = YlMediaDeliveryEngine().makeSession()
    self.released = released
    session.onState = { [weak self] id, status, failure in
      guard let self, !self.closed else { return }
      var event: [String: Any] = ["id": id, "status": status]
      if let failure {
        event["failure"] = ["code": failure.code, "category": failure.category,
          "message": "Media delivery failed."]
      }
      self.events.sendMessage(event)
    }
    channel.setMethodCallHandler { [weak self] call, reply in
      guard let self, !self.closed else { reply(YlPlayerMediaDeliveryPlugin.disposed()); return }
      do {
        switch call.method {
        case "admit":
          try self.session.validate(input: YlDeliveryWire.input(call.arguments))
          reply(true)
        case "prepare":
          let id = try YlDeliveryWire.identifier(call.arguments)
          let input = try YlDeliveryWire.input(call.arguments)
          self.session.prepare(id: id, input: input) { result in
            switch result {
            case .success(let url):
              reply(["id": id, "uri": url.absoluteString,
                "contentType": "application/vnd.apple.mpegurl", "isLive": true])
            case .failure(let error): reply(Self.failure(error))
            }
          }
        case "release":
          self.session.release(id: try YlDeliveryWire.identifier(call.arguments)); reply(nil)
        case "dispose":
          self.close(); reply(nil); self.released()
        default: reply(FlutterMethodNotImplemented)
        }
      } catch { reply(Self.failure(error)) }
    }
  }
  private static func failure(_ error: Error) -> FlutterError {
    let value = error as? NativePlayerError
    return FlutterError(code: value?.code ?? "internal.failure", message: "Media delivery failed.",
      details: ["category": value?.category ?? "internal"])
  }
  func close() {
    guard !closed else { return }
    closed = true
    session.close()
    channel.setMethodCallHandler(nil)
  }
}

/// Retain registration IDs so owner disposal also removes macOS engine records.
private final class YlDeliveryMessenger: NSObject, FlutterBinaryMessenger {
  private let underlying: FlutterBinaryMessenger
  private var connections: [String: FlutterBinaryMessengerConnection] = [:]
  init(_ underlying: FlutterBinaryMessenger) { self.underlying = underlying }
  func send(onChannel channel: String, message: Data?) { underlying.send(onChannel: channel, message: message) }
  func send(onChannel channel: String, message: Data?, binaryReply: FlutterBinaryReply?) {
    underlying.send(onChannel: channel, message: message, binaryReply: binaryReply)
  }
  func setMessageHandlerOnChannel(_ channel: String, binaryMessageHandler handler: FlutterBinaryMessageHandler?) -> FlutterBinaryMessengerConnection {
    if let old = connections.removeValue(forKey: channel) { underlying.cleanUpConnection(old) }
    guard let handler else { return 0 }
    let connection = underlying.setMessageHandlerOnChannel(channel, binaryMessageHandler: handler)
    connections[channel] = connection
    return connection
  }
  func cleanUpConnection(_ connection: FlutterBinaryMessengerConnection) {
    connections = connections.filter { $0.value != connection }
    underlying.cleanUpConnection(connection)
  }
}
