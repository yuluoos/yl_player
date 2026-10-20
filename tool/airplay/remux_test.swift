import yl_player_media_core
@testable import yl_player_media_delivery
import Foundation
import AVFoundation
import YlFFmpegBridge

func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !value() { throw NSError(domain: message, code: 1) }
}
func get(_ url: URL, method: String = "GET", range: String? = nil) throws -> (Data, HTTPURLResponse) {
  let semaphore = DispatchSemaphore(value: 0)
  var result: (Data, HTTPURLResponse)?
  var failure: Error?
  var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
  request.httpMethod = method
  request.setValue(range, forHTTPHeaderField: "Range")
  URLSession.shared.dataTask(with: request) { data, response, error in
    failure = error
    if let data, let response = response as? HTTPURLResponse { result = (data, response) }
    semaphore.signal()
  }.resume()
  guard semaphore.wait(timeout: .now() + 10) == .success else { throw NSError(domain: "HTTP timeout", code: 1) }
  if let failure { throw failure }
  return result!
}

@main struct RemuxTests {
  static func localInput(_ url: URL, isLive: Bool = false) -> YlMediaDeliveryInput {
    let container: YlFallbackContainer
    switch url.pathExtension {
    case "flv": container = .flv
    case "mp4": container = .mp4
    default: container = .matroska
    }
    return YlMediaDeliveryInput(recipe: .local(path: url.path, container: container), isLive: isLive)
  }
  static func main() throws {
    let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
    for name in ["h264_aac.mkv", "h264_aac.flv", "h264_aac.mp4", "network_seek_h264_aac.mkv"] {
      let input = localInput(fixtures.appendingPathComponent(name))
      var prepared: YlDeliveredMedia? = try YlAirPlayRemux.prepare(input: input, token: YlOpenCancellationToken())
      let url = prepared!.url
      try require(url.host != "127.0.0.1" && url.host != "localhost", "Receiver URL must use LAN interface")
      let (playlistData, response) = try get(url)
      let playlist = String(data: playlistData, encoding: .utf8)!
      try require(response.statusCode == 200 && playlist.contains("#EXT-X-ENDLIST"), "Complete HLS VOD playlist")
      let files = playlist.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)
      try require(!files.isEmpty, "HLS media segments")
      let mediaURL = url.deletingLastPathComponent().appendingPathComponent(files[0])
      let (full, _) = try get(mediaURL)
      let (partial, ranged) = try get(mediaURL, range: "bytes=0-15")
      try require(ranged.statusCode == 206 && partial == full.prefix(16), "HTTP byte range")
      try require(try get(mediaURL, range: "bytes=0-1,4-5").1.statusCode == 416, "Multiple ranges rejected")
      try require(try get(mediaURL, range: "bytes=999999999999-").1.statusCode == 416, "Out-of-bounds range rejected")
      let (suffix, suffixResponse) = try get(mediaURL, range: "bytes=-8")
      try require(suffixResponse.statusCode == 206 && suffix == full.suffix(8), "Suffix byte range")
      let (head, headResponse) = try get(mediaURL, method: "HEAD")
      try require(head.isEmpty && headResponse.expectedContentLength == full.count, "HEAD length")
      try require(try get(url, method: "POST").1.statusCode == 405, "POST forbidden")
      try require(try get(url.deletingLastPathComponent().appendingPathComponent("unlisted")).1.statusCode == 404, "Whitelist enforced")
      try require(try get(URL(string: "http://\(url.host!):\(url.port!)/wrong/index.m3u8")!).1.statusCode == 404, "Capability enforced")
      // Decode the published AAC track as PCM independently of AVPlayer's
      // video output, catching malformed AAC cookies or transport framing.
      var fragmentedMP4 = try get(url.deletingLastPathComponent().appendingPathComponent("init.mp4")).0
      for name in files { fragmentedMP4.append(try get(url.deletingLastPathComponent().appendingPathComponent(name)).0) }
      let checkURL = FileManager.default.temporaryDirectory.appendingPathComponent("yl-airplay-audio-\(UUID().uuidString).mp4")
      try fragmentedMP4.write(to: checkURL)
      defer { try? FileManager.default.removeItem(at: checkURL) }
      let asset = AVURLAsset(url: checkURL)
      let reader = try AVAssetReader(asset: asset)
      guard let audioTrack = asset.tracks(withMediaType: .audio).first else { throw NSError(domain: "Missing AAC track", code: 1) }
      let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
      reader.add(audioOutput)
      try require(reader.startReading(), "AAC decoder starts")
      var audioFrames = 0
      while let sample = audioOutput.copyNextSampleBuffer() { audioFrames += CMSampleBufferGetNumSamples(sample) }
      try require(reader.status == .completed && audioFrames > 0, "Published AAC decodes into PCM")
      let item = AVPlayerItem(url: url)
      let player = AVPlayer(playerItem: item)
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
      item.add(output)
      player.isMuted = true
      player.play()
      let deadline = Date().addingTimeInterval(20)
      var frame = false
      while Date() < deadline && (!frame || item.status != .readyToPlay || !item.duration.seconds.isFinite) && item.status != .failed {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if output.hasNewPixelBuffer(forItemTime: time), output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { frame = true }
      }
      try require(item.status == .readyToPlay, "AVPlayer ready \(name): \(String(describing: item.error))")
      try require(item.duration.seconds > 0 && item.duration.seconds.isFinite, "Finite AVPlayer duration")
      try require(frame, "AVPlayer decoded video frame \(name)")
      try require(item.tracks.contains { $0.assetTrack?.mediaType == .audio }, "AAC audio track preserved")
      if name == "network_seek_h264_aac.mkv" {
        let target = item.duration.seconds * 0.7
        var seekDone = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { success in seekDone = success }
        let seekDeadline = Date().addingTimeInterval(10)
        while !seekDone && Date() < seekDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        try require(seekDone && abs(player.currentTime().seconds - target) < 0.5, "Generated multi-segment HLS seek")
      }
      player.pause()
      player.replaceCurrentItem(with: nil)
      prepared = nil
      do {
        _ = try get(url)
        throw NSError(domain: "Released media kept HTTP server alive", code: 1)
      } catch let error as NSError { try require(error.domain == NSURLErrorDomain, "Server stops on release") }
      print("PASS \(name): HTTP/ranges, AVPlayer ready/frame/duration")
    }
    for name in ["hevc_aac.mkv", "h264_mp3.flv"] {
      do {
        _ = try YlAirPlayRemux.prepare(input: localInput(fixtures.appendingPathComponent(name)), token: .init())
        throw NSError(domain: "Unsupported codecs accepted", code: 1)
      } catch let error as NativePlayerError { try require(error.code == "airplay.unsupported_codec", "Explicit codec rejection") }
    }
    let oversized = FileManager.default.temporaryDirectory.appendingPathComponent("yl-airplay-oversized-\(UUID().uuidString).mkv")
    FileManager.default.createFile(atPath: oversized.path, contents: nil)
    let sparse = try FileHandle(forWritingTo: oversized)
    try sparse.truncate(atOffset: UInt64(YlAirPlayRemux.maximumBytes + 1))
    try sparse.close()
    defer { try? FileManager.default.removeItem(at: oversized) }
    do {
      _ = try YlAirPlayRemux.prepare(input: localInput(oversized), token: .init())
      throw NSError(domain: "Oversized input accepted", code: 1)
    } catch let error as NativePlayerError { try require(error.code == "airplay.resource_limit", "Disk/input admission limit") }
    let live = localInput(fixtures.appendingPathComponent("h264_aac.mkv"), isLive: true)
    do {
      _ = try YlAirPlayRemux.prepare(input: live, token: .init())
      throw NSError(domain: "Live source accepted", code: 1)
    } catch let error as NativePlayerError { try require(error.code == "airplay.unsupported_source", "Live source rejection") }
    let inFlight = YlOpenCancellationToken()
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.002) { inFlight.cancel() }
    do {
      _ = try YlAirPlayRemux.prepare(input: localInput(fixtures.appendingPathComponent("network_seek_h264_aac.mkv")), token: inFlight)
      throw NSError(domain: "In-flight cancellation ignored", code: 1)
    } catch let error as NativePlayerError { try require(error.code == "network.cancelled", "In-flight cancellation preserved") }
    let token = YlOpenCancellationToken()
    token.cancel()
    do {
      _ = try YlAirPlayRemux.prepare(input: localInput(fixtures.appendingPathComponent("h264_aac.mkv")), token: token)
      throw NSError(domain: "Cancellation ignored", code: 1)
    } catch let error as NativePlayerError { try require(error.code == "network.cancelled", "Cancellation preserved") }
    try require(ylf_debug_outstanding_packet_count() == 0, "No leaked FFmpeg packets")
    print("PASS unsupported codecs/live, cancellation, input limit, packet ownership")
  }
}
