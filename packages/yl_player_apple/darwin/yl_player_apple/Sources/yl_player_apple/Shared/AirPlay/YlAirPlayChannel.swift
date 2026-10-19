import Foundation
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Optional version-1 side channel: schema-7 playback messages and their commit
/// barrier remain unchanged. Registrations share the native player's lifetime.
final class YlAirPlayChannels {
  private let messenger: FlutterBinaryMessenger
  let picker = YlAirPlayRoutePickerFactory()
  private var channels: [String: FlutterBasicMessageChannel] = [:]
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }

  func install(suffix: String, host: YlApplePlayerHost?) {
    channels.removeValue(forKey: suffix)?.setMessageHandler(nil)
    picker.register(suffix: suffix, host: host)
    guard let host else { return }
    let events = FlutterBasicMessageChannel(name: "dev.ylplayer.airplay.events.\(suffix)",
      binaryMessenger: messenger, codec: FlutterStandardMessageCodec.sharedInstance())
    host.onAirPlayChanged = { [weak self] state in
      self?.picker.refresh(suffix: suffix)
      events.sendMessage(state)
    }
    let channel = FlutterBasicMessageChannel(name: "dev.ylplayer.airplay.\(suffix)",
      binaryMessenger: messenger, codec: YlPlayerApplePigeonCodec.shared)
    channel.setMessageHandler { [weak host] message, reply in
      guard let host, !host.disposed else {
        reply(["error": YlAppleFailureMapper.message(YlAppleFailureMapper.invalid("player.disposed"), scope: .command)])
        return
      }
      guard let arguments = message as? [String: Any], let method = arguments["method"] as? String else {
        reply(["error": YlAppleFailureMapper.message(YlAppleFailureMapper.invalid(), scope: .command)])
        return
      }
      do {
        switch method {
        case "state": reply(["value": host.airPlayState])
        case "assess":
          guard let request = arguments["request"] as? AppleAssessRequest else { throw YlAppleFailureMapper.invalid() }
          reply(["value": try host.assessAirPlay(request: request)])
        case "load":
          guard let request = arguments["request"] as? AppleLoadRequest else { throw YlAppleFailureMapper.invalid() }
          Task { @MainActor in
            do { reply(["value": try await host.loadAirPlay(request: request)]) }
            catch { reply(["error": YlAppleFailureMapper.message(error, scope: .command)]) }
          }
        default: throw YlAppleFailureMapper.unsupported
        }
      } catch { reply(["error": YlAppleFailureMapper.message(error, scope: .command)]) }
    }
    channels[suffix] = channel
  }
}
