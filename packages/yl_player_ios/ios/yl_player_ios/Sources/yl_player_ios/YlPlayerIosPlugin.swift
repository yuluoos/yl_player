import AVFoundation
import Flutter
import UIKit

public final class YlPlayerIosPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let textures: FlutterTextureRegistry
  private var players: [Int64: YlIosPlayer] = [:]
  private var nextPlayerId: Int64 = 1
  private var eventSink: FlutterEventSink?
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
    lifecycleObservers = [
      NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.deactivateAllPlayers() },
      NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.deactivateAllPlayers() },
    ]
  }

  deinit {
    lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    players.values.forEach { $0.dispose() }
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = YlPlayerIosPlugin(textures: registrar.textures())
    let methods = FlutterMethodChannel(
      name: "dev.ylplayer.yl_player_ios/methods",
      binaryMessenger: registrar.messenger()
    )
    let events = FlutterEventChannel(
      name: "dev.ylplayer.yl_player_ios/events",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methods)
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "create":
      create(call.arguments, result: result)
    case "command":
      command(call.arguments, result: result)
    case "dispose":
      dispose(call.arguments, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    eventSink = events
    players.values.forEach { $0.emitState() }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  private func create(_ arguments: Any?, result: @escaping FlutterResult) {
    let root = stringMap(arguments)
    let configuration = PlayerConfiguration(map: stringMap(root["configuration"]))
    let playerId = nextPlayerId
    nextPlayerId += 1
    let nativePlayer = YlIosPlayer(
      playerId: playerId,
      textures: textures,
      configuration: configuration,
      emit: { [weak self] event in self?.eventSink?(event) }
    )
    let textureId = textures.register(nativePlayer)
    nativePlayer.textureId = textureId
    players[playerId] = nativePlayer
    result(["playerId": playerId, "textureId": textureId])
  }

  private func command(_ arguments: Any?, result: @escaping FlutterResult) {
    let root = stringMap(arguments)
    guard let playerId = int64(root["playerId"]), let player = players[playerId] else {
      result(flutterError(NativePlayerError(
        category: "resource",
        code: "ios.player_missing",
        message: "The requested iOS player does not exist."
      )))
      return
    }
    do {
      let commandName = root["name"] as? String ?? ""
      let commandArguments = stringMap(root["arguments"])
      if commandName == "open" {
        try player.validateOpen(stringMap(commandArguments["source"]))
      }
      if commandName == "open" || commandName == "play" {
        players.values.filter { $0 !== player }.forEach { $0.deactivate() }
        try player.activate()
      }
      try player.command(name: commandName, arguments: commandArguments)
      result(nil)
    } catch let error as NativePlayerError {
      result(flutterError(error))
    } catch {
      result(flutterError(NativePlayerError(
        category: "internal",
        code: "ios.command_failed",
        message: "iOS player command failed.",
        diagnostic: String(describing: error)
      )))
    }
  }

  private func dispose(_ arguments: Any?, result: @escaping FlutterResult) {
    let root = stringMap(arguments)
    if let playerId = int64(root["playerId"]), let player = players.removeValue(forKey: playerId) {
      player.dispose()
      if !players.values.contains(where: { $0.isActive }) {
        deactivateAudioSession()
      }
    }
    result(nil)
  }

  private func deactivateAllPlayers() {
    players.values.forEach { $0.deactivate() }
    deactivateAudioSession()
  }

  private func deactivateAudioSession() {
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }
}
