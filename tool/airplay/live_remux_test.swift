import yl_player_media_core
@testable import yl_player_media_delivery
import AVFoundation
import Foundation
import YlFFmpegBridge

@main struct LiveRemuxTests {
  static func main() throws {
    setbuf(stdout, nil)
    let sourceURL = URL(string: CommandLine.arguments[1])!
    let recipe: YlFallbackSourceRecipe
    if ["rtmp", "rtmps"].contains(sourceURL.scheme?.lowercased() ?? "") {
      recipe = .rtmp(request: YlRtmpRequestRecipe(address: try YlRtmpAddress(sourceURL.absoluteString),
        recovery: YlRtmpRecoveryBudget(), bufferScope: try YlManagedBufferLedger().makeScope(maxBytes: nil)))
    } else {
      recipe = .network(request: YlNetworkRequestRecipe(url: sourceURL, headers: [:],
        configuration: YlNetworkConfiguration(map: [:]), mode: .sequentialLive), container: .flv)
    }
    let input = YlMediaDeliveryInput(recipe: recipe, isLive: true)
    let token = YlOpenCancellationToken()
    let expectsError = CommandLine.arguments.contains("--expect-config-error")
    var media: YlDeliveredMedia?
    do {
      media = try YlAirPlayLiveRemux.prepare(input: input, token: token)
      if expectsError { fatalError("Changed live configuration was accepted") }
    } catch let error as NativePlayerError {
      guard expectsError, error.code == "airplay.unsupported_codec" else { throw error }
      print("PASS production input rejects live configuration change: \(error.message)")
      return
    }
    token.cancel() // Superseded load tokens must not cancel an accepted producer.
    media!.observeFailure { error in print("PRODUCER FAILURE: \(error.code): \(error.message)") }
    print("LIVE URL: \(media!.url)")
    let playlist = try String(contentsOf: media!.url, encoding: .utf8)
    precondition(!playlist.contains("#EXT-X-ENDLIST"), "Live playlist unexpectedly ended")
    let item = AVPlayerItem(url: media!.url)
    let player = AVPlayer(playerItem: item)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    item.add(output); player.isMuted = true; player.play()
    let deadline = Date().addingTimeInterval(20)
    var frame = false
    while Date() < deadline && (!frame || item.status != .readyToPlay) && item.status != .failed {
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
      let time = output.itemTime(forHostTime: CACurrentMediaTime())
      if output.hasNewPixelBuffer(forItemTime: time), output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil { frame = true }
    }
    guard item.status == .readyToPlay, frame else {
      print("status=\(item.status.rawValue) rate=\(player.rate) control=\(player.timeControlStatus.rawValue) time=\(player.currentTime().seconds) ranges=\(item.seekableTimeRanges) logs=\(String(describing: item.errorLog()?.events))")
      throw NSError(domain: "Live HLS video failed: \(String(describing: item.error))", code: 1)
    }
    print("PASS continuous live HLS ready and decoded video; obsolete load cancellation preserved producer")
    if CommandLine.arguments.contains("--reconnect") {
      // The fixture atomically disconnects the stream and reports an upper
      // bound for every original-period video PTS emitted, including packets
      // still buffered in the network/demux/writer. Playlist sums cannot prove it.
      let control = try Data(contentsOf: sourceURL.deletingLastPathComponent().appendingPathComponent("disconnect"))
      guard let bound = String(data: control, encoding: .utf8), let oldEnd = Double(bound) else {
        fatalError("Fixture did not return its original-period PTS upper bound")
      }
      let recoveryDeadline = Date().addingTimeInterval(40)
      var recovered = false
      while Date() < recoveryDeadline && !recovered && item.status != .failed {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        var displayed = CMTime.invalid
        if time.seconds > oldEnd + 0.1, output.hasNewPixelBuffer(forItemTime: time),
           output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayed) != nil,
           displayed.seconds > oldEnd + 0.1 {
          let current = try String(contentsOf: media!.url, encoding: .utf8)
          recovered = current.contains("init-1.mp4")
          if recovered { print("Decoded new-period frame PTS=\(displayed.seconds), original upper bound=\(oldEnd)") }
        }
      }
      precondition(recovered, "No decoded new-period video after upstream reconnect")
      print("PASS same AVPlayerItem decoded new-period video beyond source-proven old PTS bound \(oldEnd) after forced disconnect")
    }
    player.pause(); player.replaceCurrentItem(with: nil); media = nil
    Thread.sleep(forTimeInterval: 0.5)
    precondition(ylf_debug_outstanding_packet_count() == 0, "Live packet ownership leaked after teardown")
  }
}
