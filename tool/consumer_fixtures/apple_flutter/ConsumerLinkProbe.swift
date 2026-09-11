import YlFFmpegBridge
import yl_player_apple

@_cdecl("yl_consumer_link_probe")
func ylConsumerLinkProbe() -> UnsafePointer<CChar>? {
  _ = YlPlayerApplePlugin.self
  return ylf_build_configuration()
}
