import AVFoundation
import Flutter
import UIKit

public final class YlPlayerIosPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let textures: FlutterTextureRegistry
  private var players: [Int64: YlIosPlayer] = [:]
  private var nextPlayerId: Int64 = 1
  private var eventSink: FlutterEventSink?
  private var lifecycleObservers: [NSObjectProtocol] = []
  private var suspendedPlayerIds = Set<Int64>()

  init(textures: FlutterTextureRegistry) {
    self.textures = textures
    super.init()
    lifecycleObservers = [
      NotificationCenter.default.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.suspendActivePlayers() },
      NotificationCenter.default.addObserver(
        forName: UIApplication.didReceiveMemoryWarningNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.handleMemoryWarning() },
      NotificationCenter.default.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.reactivateSuspendedPlayers() },
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
    let commandName = root["name"] as? String ?? ""
    let commandArguments = stringMap(root["arguments"])
    if commandName == "stop" { suspendedPlayerIds.remove(playerId) }
    if commandName == "open" {
      player.beginOpen(
        stringMap(commandArguments["source"]),
        didCommit: { [weak self, weak player] in
          guard let self, let player else { return }
          self.suspendedPlayerIds.remove(playerId)
          self.players.values.filter { $0 !== player }.forEach { $0.deactivate() }
        },
        completion: { openResult in
          switch openResult {
          case .success:
            result(nil)
          case let .failure(error):
            result(flutterError(error))
          }
        }
      )
      return
    }
    if commandName == "play" {
      player.beginActivation(
        forcePlay: true,
        didCommit: { [weak self, weak player] in
          guard let self, let player else { return }
          self.suspendedPlayerIds.remove(playerId)
          self.players.values.filter { $0 !== player }.forEach { $0.deactivate() }
        },
        completion: { activationResult in
          switch activationResult {
          case .success:
            player.beginCommand(name: commandName, arguments: commandArguments) {
              commandResult in
              switch commandResult {
              case .success: result(nil)
              case let .failure(error): result(flutterError(error))
              }
            }
          case let .failure(error):
            result(flutterError(error))
          }
        }
      )
      return
    }
    player.beginCommand(name: commandName, arguments: commandArguments) {
      commandResult in
      switch commandResult {
      case .success: result(nil)
      case let .failure(error): result(flutterError(error))
      }
    }
  }

  private func dispose(_ arguments: Any?, result: @escaping FlutterResult) {
    let root = stringMap(arguments)
    if let playerId = int64(root["playerId"]), let player = players.removeValue(forKey: playerId) {
      suspendedPlayerIds.remove(playerId)
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

  private func suspendActivePlayers() {
    suspendedPlayerIds.formUnion(
      players.compactMap { playerId, player in player.isActive ? playerId : nil }
    )
    deactivateAllPlayers()
  }

  private func handleMemoryWarning() {
    players.values.forEach { $0.handleMemoryWarning() }
    deactivateAudioSession()
  }

  private func reactivateSuspendedPlayers() {
    let playerIds = suspendedPlayerIds
    for playerId in playerIds {
      guard let player = players[playerId] else {
        suspendedPlayerIds.remove(playerId)
        continue
      }
      player.beginActivation(
        forcePlay: false,
        didCommit: { [weak self, weak player] in
          guard let self, let player else { return }
          self.players.values.filter { $0 !== player }.forEach { $0.deactivate() }
        },
        completion: { [weak self, weak player] result in
          guard let self else { return }
          switch result {
          case .success:
            self.suspendedPlayerIds.remove(playerId)
          case let .failure(error) where error.code == "network.cancelled":
            break
          case let .failure(error):
            self.suspendedPlayerIds.remove(playerId)
            player?.emitError(error)
          }
        }
      )
    }
  }

  private func deactivateAudioSession() {
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
  }
}
