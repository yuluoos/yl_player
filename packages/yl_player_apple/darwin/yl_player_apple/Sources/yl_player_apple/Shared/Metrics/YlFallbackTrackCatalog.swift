import Foundation
import YlFFmpegBridge

enum YlFallbackTrackCatalog {
  static func audioTracks(
    streams: [YLFStreamInfo],
    selectedIndex: Int32?,
    codecName: (YLFStreamInfo) -> String
  ) -> [YlNativeTrack] {
    streams.map { stream in
      let codec = codecName(stream)
      return YlNativeTrack(id: "audio-\(stream.index)", kind: .audio,
        label: "\(codec) \(stream.index)", language: nil, codec: codec,
        isSelected: stream.index == selectedIndex)
    }
  }

  static func videoTrack(
    stream: YLFStreamInfo,
    codecName: String,
    bitrate: Int?
  ) -> YlNativeTrack {
    YlNativeTrack(id: "video-\(stream.index)", kind: .video,
      codec: canonicalVideoCodec(codecName), bitrate: bitrate,
      width: Int(stream.width), height: Int(stream.height), isSelected: true)
  }

  private static func canonicalVideoCodec(_ codecName: String) -> String {
    switch codecName.lowercased() {
    case "h264", "avc", "video/avc":
      return "video/avc"
    case "h265", "hevc", "video/hevc":
      return "video/hevc"
    default:
      return codecName
    }
  }
}
