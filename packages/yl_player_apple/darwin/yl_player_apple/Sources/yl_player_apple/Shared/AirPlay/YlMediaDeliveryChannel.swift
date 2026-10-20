import Foundation
#if os(iOS)
import Flutter
#else
import FlutterMacOS
#endif

/// Optional delivery transport; shared source codecs retain their schema.
final class YlMediaDeliveryChannels {
  private let messenger: FlutterBinaryMessenger
  private var channels: [String: FlutterBasicMessageChannel] = [:]
  init(messenger: FlutterBinaryMessenger) { self.messenger = messenger }
  func install(suffix: String, host: YlApplePlayerHost?) {
    channels.removeValue(forKey: suffix)?.setMessageHandler(nil)
    guard let host else { return }
    let events = FlutterBasicMessageChannel(name: "dev.ylplayer.delivery.events.\(suffix)", binaryMessenger: messenger, codec: YlPlayerApplePigeonCodec.shared)
    host.mediaDelivery.onState = { events.sendMessage($0) }
    let channel = FlutterBasicMessageChannel(name: "dev.ylplayer.delivery.\(suffix)", binaryMessenger: messenger, codec: YlPlayerApplePigeonCodec.shared)
    channel.setMessageHandler { [weak host] message, reply in
      guard let host, !host.disposed else {
        reply(["error": YlAppleFailureMapper.message(YlAppleFailureMapper.invalid("player.disposed"), scope: .command)]); return
      }
      do {
        guard let arguments = message as? [String: Any], let method = arguments["method"] as? String,
              let id = arguments["id"] as? String, id.range(of: "^d[0-9]{1,18}$", options: .regularExpression) != nil else { throw YlAppleFailureMapper.invalid() }
        switch method {
        case "admit":
          guard let request = arguments["request"] as? AppleAssessRequest else { throw YlAppleFailureMapper.invalid() }
          _ = try host.admitMediaDelivery(request: request)
          reply(["value": true])
        case "prepare":
          guard let request = arguments["request"] as? AppleAssessRequest else { throw YlAppleFailureMapper.invalid() }
          try host.prepareMediaDelivery(id: id, request: request) { result in
            switch result {
            case .success(let value): reply(["value": value])
            case .failure(let error): reply(["error": YlAppleFailureMapper.message(error, scope: .command)])
            }
          }
        case "release": host.mediaDelivery.release(id: id); reply(["value": true])
        default: throw YlAppleFailureMapper.unsupported
        }
      } catch { reply(["error": YlAppleFailureMapper.message(error, scope: .command)]) }
    }
    channels[suffix] = channel
  }
}
