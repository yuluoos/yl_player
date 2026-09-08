import Cocoa
import FlutterMacOS

public final class YlPlayerMacosPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  static let methodChannelName = "dev.ylplayer.yl_player_macos/methods"
  static let eventChannelName = "dev.ylplayer.yl_player_macos/events"

  private let textures: FlutterTextureRegistry
  private weak var displayView: NSView?
  private var players: [Int64: YlMacosPlayer] = [:]
  private var nextPlayerId: Int64 = 1
  private var eventSink: FlutterEventSink?
  private var lifecycleObservers: [NSObjectProtocol] = []

  init(textures: FlutterTextureRegistry, displayView: NSView? = nil) {
    self.displayView = displayView
    self.textures = textures
    super.init()
    lifecycleObservers = [
      NotificationCenter.default.addObserver(
        forName: NSApplication.didResignActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.handleLifecycle(.didResignActive) },
      NotificationCenter.default.addObserver(
        forName: NSApplication.didBecomeActiveNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.handleLifecycle(.didBecomeActive) },
      NotificationCenter.default.addObserver(
        forName: NSApplication.willTerminateNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in self?.handleLifecycle(.willTerminate) },
    ]
  }

  deinit {
    lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    disposeAllPlayers()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = YlPlayerMacosPlugin(textures: registrar.textures, displayView: registrar.view)
    let methods = FlutterMethodChannel(
      name: methodChannelName,
      binaryMessenger: registrar.messenger
    )
    let events = FlutterEventChannel(
      name: eventChannelName,
      binaryMessenger: registrar.messenger
    )
    registrar.addMethodCallDelegate(instance, channel: methods)
    events.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "create": create(call.arguments, result: result)
    case "command": command(call.arguments, result: result)
    case "dispose": dispose(call.arguments, result: result)
    default: result(FlutterMethodNotImplemented)
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
    nextPlayerId &+= 1
    let nativePlayer = YlMacosPlayer(
      playerId: playerId,
      textures: textures,
      configuration: configuration,
      displayView: displayView,
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
        code: "macos.player_missing",
        message: "The requested macOS player does not exist."
      )))
      return
    }
    let name = root["name"] as? String ?? ""
    let commandArguments = stringMap(root["arguments"])
    if name == "requestState" { player.emitState(); result(nil); return }

    if name == "open" {
      var quiescedPlayers = [YlMacosPlayer]()
      player.beginOpen(
        stringMap(commandArguments["source"]),
        willCommit: { [weak self, weak player] requiresLease in
          guard requiresLease, let self, let player else { return }
          quiescedPlayers = self.quiesceOtherPlayers(for: player)
        },
        didCommit: { [weak self, weak player] in
          guard let self, let player else { return }
          self.players.values.filter { $0 !== player }.forEach { $0.deactivate() }
          quiescedPlayers.removeAll()
        },
        didRollback: {
          quiescedPlayers.forEach { $0.restoreAfterHardwareDecoderRollback() }
          quiescedPlayers.removeAll()
        },
        completion: { commandResult in
          switch commandResult {
          case .success:
            let token = stringMap(commandArguments["source"])["loadToken"] ?? nil
            result(token == nil ? nil : ["loadToken": token])
          case let .failure(error): result(flutterError(error))
          }
        }
      )
      return
    }

    let runCommand = {
      player.beginCommand(name: name, arguments: commandArguments) { commandResult in
        switch commandResult {
        case .success: result(nil)
        case let .failure(error): result(flutterError(error))
        }
      }
    }
    guard name == "play" else {
      runCommand()
      return
    }
    var quiescedPlayers = [YlMacosPlayer]()
    player.beginActivation(
      forcePlay: true,
      willCommit: { [weak self, weak player] requiresLease in
        guard requiresLease, let self, let player else { return }
        quiescedPlayers = self.quiesceOtherPlayers(for: player)
      },
      didCommit: { [weak self, weak player] in
        guard let self, let player else { return }
        self.players.values.filter { $0 !== player }.forEach { $0.deactivate() }
        quiescedPlayers.removeAll()
      },
      didRollback: {
        quiescedPlayers.forEach { $0.restoreAfterHardwareDecoderRollback() }
        quiescedPlayers.removeAll()
      },
      completion: { activationResult in
        switch activationResult {
        case .success: runCommand()
        case let .failure(error): result(flutterError(error))
        }
      }
    )
  }

  private func dispose(_ arguments: Any?, result: @escaping FlutterResult) {
    let root = stringMap(arguments)
    if let playerId = int64(root["playerId"]),
       let player = players.removeValue(forKey: playerId) {
      player.dispose()
    }
    result(nil)
  }

  private func handleLifecycle(_ event: YlMacosLifecycleEvent) {
    switch YlMacosLifecyclePolicy.action(for: event) {
    case .preserve:
      break
    case .emitState:
      players.values.forEach { $0.emitState() }
    case .disposeAll:
      disposeAllPlayers()
    }
  }

  private func disposeAllPlayers() {
    let activePlayers = players.values
    players.removeAll()
    activePlayers.forEach { $0.dispose() }
  }

  private func quiesceOtherPlayers(for player: YlMacosPlayer) -> [YlMacosPlayer] {
    let activePlayers = players.values.filter { $0 !== player && $0.isActive }
    activePlayers.forEach { $0.quiesceForHardwareDecoderLease() }
    return activePlayers
  }
}
