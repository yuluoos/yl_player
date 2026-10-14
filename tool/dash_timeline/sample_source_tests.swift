import Foundation
import CoreMedia
import YlFFmpegBridge
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var rows: [[String: Any]] = []
let originalCount = ylf_debug_outstanding_packet_count()
for directory in ["period0", "independent"] {
  for track in [0, 1] {
    for number in [1, 4] {
      let folder = root.appendingPathComponent(directory)
      let initURL = folder.appendingPathComponent("init-\(track).m4s")
      let fragmentURL = folder.appendingPathComponent(String(format: "chunk-%d-%05d.m4s", track, number))
      let ledger = YlManagedBufferLedger(maxBytes: 4 * 1024 * 1024)
      let scope = try ledger.makeScope(maxBytes: nil)
      var source: YlDashSampleSource? = try YlDashSampleSource(
        initialization: .init(data: Data(contentsOf: initURL), finalURL: initURL, credentialsStripped: false, resourceLength: nil, reservation: nil),
        fragment: .init(data: Data(contentsOf: fragmentURL), finalURL: fragmentURL, credentialsStripped: false, resourceLength: nil, reservation: nil),
        kind: track == 0 ? .video : .audio, cancellation: .init(), scope: scope)
      var packets: [[Int64]] = []
      var retainedSample: CMSampleBuffer?
      while let packet = try source!.next() {
        packets.append([packet.pts.numerator, packet.pts.denominator, packet.duration.numerator, packet.duration.denominator])
        if track == 0 {
          let output = try packet.videoSample(format: source!.videoFormat!, pts: CMTime(value: packet.pts.numerator, timescale: Int32(packet.pts.denominator)), dts: .invalid, duration: CMTime(value: packet.duration.numerator, timescale: Int32(packet.duration.denominator)))
          if retainedSample == nil { retainedSample = output }
          precondition(CMSampleBufferGetPresentationTimeStamp(output).value == packet.pts.numerator)
        } else { let bytes = try packet.audioBytes(); precondition(!bytes.isEmpty) }
      }
      source = nil
      if track == 0 { precondition(ledger.snapshot.currentBytes > 0 && CMSampleBufferGetTotalSampleSize(retainedSample!) > 0) }
      retainedSample = nil
      precondition(ledger.snapshot.currentBytes == 0)
      rows.append(["directory": directory, "track": track, "fragment": number, "packets": packets])
    }
  }
}
precondition(ylf_debug_outstanding_packet_count() == originalCount)
print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]), as: UTF8.self))
