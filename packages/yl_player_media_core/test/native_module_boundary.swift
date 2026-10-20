import Foundation
import yl_player_media_core

let configuration = YlNetworkConfiguration(connectTimeoutMs: 70_000, readTimeoutMs: 80_000,
  maxRetries: 21, baseRetryDelayMs: 70_000, maxRetryDelayMs: 90_000, maxRedirects: 22)
precondition(configuration.connectTimeoutMs == 70_000)
precondition(configuration.maxRetries == 21)
let token = YlOpenCancellationToken()
var cancelled = false
token.onCancel { cancelled = true }
token.cancel()
precondition(cancelled && token.isCancelled)
let address = try YlRtmpAddress("rtmp://example.com/live/test")
precondition(address.host == "example.com")
let error = NativePlayerError(category: "network", code: "test", message: "https://secret", diagnostic: "secret")
precondition(!error.description.contains("secret"))
precondition(error.description == "Playback operation failed.")
let ledger = YlManagedBufferLedger(maxBytes: 8 * 1024 * 1024)
let scope = try ledger.makeScope(maxBytes: nil)
let held = try scope.require(category: .networkCache, bytes: 128)
precondition(ledger.snapshot.currentBytes == 128)
held.release()
precondition(ledger.snapshot.currentBytes == 0)
let rtmp = YlRtmpRequestRecipe(address: address, recovery: YlRtmpRecoveryBudget(), bufferScope: scope)
let recipe = YlFallbackSourceRecipe.rtmp(request: rtmp)
precondition(recipe.isRtmp && recipe.container == .flv)
let network = YlNetworkRequestRecipe(
  url: URL(string: "https://example.com/live/stream.flv")!,
  headers: [:], configuration: configuration, mode: .sequentialLive,
  bufferScope: scope)
let delivery = YlMediaDeliveryInput(
  recipe: .network(request: network, container: .flv), isLive: true)
precondition(delivery.isLive && delivery.recipe.container == .flv)
let hls = try YlHlsMediaPlaylist.parse(
  data: Data("#EXTM3U\n#EXTINF:2,\na.ts\n#EXT-X-ENDLIST\n".utf8),
  baseURL: URL(string: "https://example.com/live/index.m3u8")!)
precondition(hls.segments.count == 1 && hls.durationUs == 2_000_000)
print("media core module boundary passed")
