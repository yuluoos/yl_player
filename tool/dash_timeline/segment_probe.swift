import AVFoundation
import CoreVideo
import Foundation

// Feasibility probe only: reads one owned initialization/fragment pair. The
// production route remains gated until original sample timing is demonstrated.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var rows: [[String: Any]] = []
for directory in ["period0", "independent"] {
  for track in [0, 1] {
    for number in [1, 4] {
      let folder = root.appendingPathComponent(directory)
      let bytes = try Data(contentsOf: folder.appendingPathComponent("init-\(track).m4s")) + Data(contentsOf: folder.appendingPathComponent(String(format: "chunk-%d-%05d.m4s", track, number)))
      let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
      try bytes.write(to: file); defer { try? FileManager.default.removeItem(at: file) }
      for decoded in [false, true] {
        let asset = AVURLAsset(url: file)
        let reader = try AVAssetReader(asset: asset)
        guard let source = asset.tracks(withMediaType: track == 0 ? .video : .audio).first else { fatalError("Missing track") }
        let settings: [String: Any]? = decoded ? track == 0 ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] : [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: false, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsNonInterleaved: false] : nil
        let output = AVAssetReaderTrackOutput(track: source, outputSettings: settings)
        output.alwaysCopiesSampleData = false; reader.add(output)
        var row: [String: Any] = ["directory": directory, "track": track, "fragment": number, "decoded": decoded, "started": reader.startReading()]
        var count = 0, sampleCount = 0, first: CMTime?, last: CMTime?, end: CMTime?, rgb: [Int]?
        while let sample = output.copyNextSampleBuffer() {
          let pts = CMSampleBufferGetPresentationTimeStamp(sample), duration = CMSampleBufferGetDuration(sample)
          if first == nil { first = pts }
          last = pts; end = CMTimeAdd(pts, duration)
          count += 1; sampleCount += CMSampleBufferGetNumSamples(sample)
          if let buffer = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            if let base = CVPixelBufferGetBaseAddress(buffer) {
              let p = base.advanced(by: CVPixelBufferGetHeight(buffer) / 2 * CVPixelBufferGetBytesPerRow(buffer) + CVPixelBufferGetWidth(buffer) / 2 * 4).assumingMemoryBound(to: UInt8.self)
              rgb = [Int(p[2]), Int(p[1]), Int(p[0])]
            }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
          }
        }
        row["buffers"] = count; row["samples"] = sampleCount; row["status"] = reader.status.rawValue
        for (key, value) in [("first", first), ("last", last), ("end", end)] {
          if let value { row[key] = [value.value, Int64(value.timescale)] }
        }
        if let rgb { row["rgb"] = rgb }
        if let error = reader.error { row["error"] = error.localizedDescription }
        rows.append(row)
      }
    }
  }
}
print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self))
