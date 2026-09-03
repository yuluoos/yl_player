import CoreVideo
import Flutter
import Foundation

final class YlIosPlayer: NSObject, FlutterTexture {
  let playerId: Int64
  var textureId: Int64 = -1 {
    didSet { avBackend.textureId = textureId }
  }
  var isActive: Bool { slot.current.isActive }

  private enum PendingOpen {
    case avPlayer([String: Any?])
    case fallback([String: Any?], YlPreparedFallback)
  }

  private let textures: FlutterTextureRegistry
  private let configuration: PlayerConfiguration
  private let emit: ([String: Any?]) -> Void
  private let avBackend: YlAvPlayerBackend
  private let slot: YlBackendSlot
  private var pendingOpen: PendingOpen?
  private var disposed = false

  init(
    playerId: Int64,
    textures: FlutterTextureRegistry,
    configuration: PlayerConfiguration,
    emit: @escaping ([String: Any?]) -> Void
  ) {
    self.playerId = playerId
    self.textures = textures
    self.configuration = configuration
    self.emit = emit
    let avBackend = YlAvPlayerBackend(
      playerId: playerId,
      textures: textures,
      configuration: configuration,
      emit: emit
    )
    self.avBackend = avBackend
    self.slot = YlBackendSlot(initial: avBackend)
    super.init()
  }

  func validateOpen(_ source: [String: Any?]) throws {
    guard !disposed else {
      throw NativePlayerError(
        category: "resource",
        code: "ios.player_disposed",
        message: "The iOS player has been disposed."
      )
    }
    let headers = stringMap(source["headers"]).compactMapValues { $0 as? String }
    let descriptor = YlIosSourceDescriptor(
      uri: source["uri"] as? String ?? "",
      kind: source["kind"] as? String ?? "",
      formatHint: source["formatHint"] as? String ?? "automatic",
      isLive: source["isLive"] as? Bool ?? false,
      hasHeaders: !headers.isEmpty
    )
    switch YlSourceRouter.route(descriptor) {
    case .avPlayer:
      try avBackend.validateOpen(source)
      pendingOpen = .avPlayer(source)
    case .localMatroska:
      pendingOpen = .fallback(source, try YlPreparedFallback(source: source))
    case .networkMatroska:
      throw NativePlayerError(
        category: "container",
        code: "container.native_fallback_required",
        message: "Network Matroska preparation is not connected yet."
      )
    case let .reject(category, code, message):
      throw NativePlayerError(category: category, code: code, message: message)
    }
  }

  func activate() throws {
    if pendingOpen == nil {
      try slot.current.activate()
    }
  }

  func deactivate() {
    slot.current.deactivate()
  }

  func command(name: String, arguments: [String: Any?]) throws {
    guard name == "open" else {
      try slot.current.command(name: name, arguments: arguments)
      return
    }
    guard let pendingOpen else {
      throw NativePlayerError(
        category: "internal",
        code: "internal.fallback_invariant",
        message: "Open was not validated before execution."
      )
    }
    self.pendingOpen = nil
    switch pendingOpen {
    case let .avPlayer(source):
      if slot.current !== avBackend {
        let previous = try slot.replace { avBackend }
        previous.dispose()
      } else {
        try avBackend.activate()
      }
      try avBackend.command(name: "open", arguments: ["source": source])
    case let .fallback(source, prepared):
      let backend = try YlFallbackBackend(
        playerId: playerId,
        textureId: textureId,
        textures: textures,
        configuration: configuration,
        prepared: prepared,
        generation: slot.generation &+ 1,
        emit: emit
      )
      let previous = try slot.replace { backend }
      if previous !== avBackend { previous.dispose() }
      try backend.command(name: "open", arguments: ["source": source])
    }
  }

  func emitState() {
    slot.current.emitState()
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    slot.current.copyPixelBuffer()
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    pendingOpen = nil
    avBackend.textureId = -1
    let current = slot.current
    slot.dispose()
    if current !== avBackend { avBackend.dispose() }
    if textureId >= 0 {
      textures.unregisterTexture(textureId)
      textureId = -1
    }
  }

  deinit {
    dispose()
  }
}
