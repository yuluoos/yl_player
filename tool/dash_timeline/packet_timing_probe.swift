import Foundation
import CoreMedia
import Darwin
import YlFFmpegBridge

// Exercises the existing shipped bridge. The optional symbol is deliberately
// resolved at runtime so the pre-change artifact gives an executable RED.
typealias RawTiming = @convention(c) (OpaquePointer?, UnsafeMutablePointer<Int64>?, UnsafeMutablePointer<Int64>?, UnsafeMutablePointer<Int64>?) -> Int32
let handle = dlopen(nil, RTLD_NOW)!
guard let symbol = dlsym(handle, "ylf_packet_raw_timestamps") else {
  print("FAIL: shipped bridge lacks raw packet timestamps; microseconds are not the exact sample clock")
  exit(1)
}
let raw = unsafeBitCast(symbol, to: RawTiming.self)
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var rows: [[String: Any]] = []
for directory in ["period0", "independent"] {
  for track in [0, 1] {
    for number in [1, 4] {
      let folder = root.appendingPathComponent(directory)
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
      let bytes = try Data(contentsOf: folder.appendingPathComponent("init-\(track).m4s")) + Data(contentsOf: folder.appendingPathComponent(String(format: "chunk-%d-%05d.m4s", track, number)))
      try bytes.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
      var context: YLFMediaContextRef?, info = YLFMediaInfo()
      guard ylf_open_local(file.path, &context, &info) == 0 else { fatalError("open") }
      defer { ylf_close(&context) }
      var stream = YLFStreamInfo(); precondition(ylf_copy_stream_info(context, 0, &stream) == 0)
      var samples: [[Int64]] = []
      while true {
        var packet: YLFPacketRef?
        let result = ylf_read_packet(context, &packet)
        if result == YLFResultEOF { break }
        guard result == 0, let owned = packet else { fatalError("read") }
        defer { ylf_packet_release(&packet) }
        var pts: Int64 = 0, dts: Int64 = 0, duration: Int64 = 0
        precondition(raw(owned, &pts, &dts, &duration) == 0)
        samples.append([pts, dts, duration])
      }
      rows.append(["directory": directory, "track": track, "fragment": number,
        "timeBase": [stream.time_base_num, stream.time_base_den], "packets": samples])
    }
  }
}
var invalidPTS: Int64 = 0, invalidDTS: Int64 = 0, invalidDuration: Int64 = 0
precondition(raw(nil, &invalidPTS, &invalidDTS, &invalidDuration) == YLFResultInvalidArgument)
print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self))
