// Standalone harness: app configuration/network boundaries are substituted;
// local demux, compressed samples, muxer, server and AVPlayer are production code.
import Foundation
import YlFFmpegBridge
struct NativePlayerError: Error { let category: String; let code: String; let message: String; var diagnostic: String? = nil }
enum YlSourceKind { case file, network }
enum YlSourceFormat { case automatic, hls, dash, matroska, webm, flv, mp4, mov, avi, mpegTs, mpegPs }
enum YlSourceIntent { case automatic, onDemand, live }
enum YlNetworkPolicy { case platformDefault, managed }
struct YlAppleSourceDescriptor {
  var uri: String; var kind: YlSourceKind
  var formatHint: YlSourceFormat = .automatic
  var intent: YlSourceIntent = .automatic
  var drm: String? = nil
  var headers: [String: String] = [:]; var credentials: [String: String] = [:]
  var credentialContext = 0; var networkConfiguration: Int? = nil
  var networkPolicy: YlNetworkPolicy = .platformDefault; var managedRequestIntent = 0
  var isLive: Bool { intent == .live }; var url: URL? { URL(string: uri) }
}
struct YlNetworkConfiguration { init() {}; init(options: Int) {} }
struct PlayerConfiguration { var network = YlNetworkConfiguration() }
enum YlFallbackContainer { case matroska, flv, mp4, avi, mpegTs, mpegPs }
enum YlNetworkInputMode { case randomAccessVOD }
struct YlNetworkRequestRecipe {
  init(url: URL, headers: [String: String], credentials: [String: String], credentialContext: Int, configuration: YlNetworkConfiguration, mode: YlNetworkInputMode, managedIntent: Int?) {}
}
enum YlFallbackSourceRecipe { case local(path: String, container: YlFallbackContainer); case network(request: YlNetworkRequestRecipe, container: YlFallbackContainer) }
class YlByteSource { func cancel() {} }
final class YlOpenedMedia {
  var context: YLFMediaContextRef?
  var info = YLFMediaInfo()
  var lastInputError: NativePlayerError? { nil }
  init(recipe: YlFallbackSourceRecipe, networkBufferBytes: Int, onSourceCreated: ((YlByteSource) -> Void)?) throws {
    guard case let .local(path, _) = recipe else { fatalError("Network boundary excluded from standalone harness") }
    guard path.withCString({ ylf_open_local($0, &context, &info) }) == YLFResultOK else { throw NativePlayerError(category: "container", code: "open", message: "open failed") }
  }
  func seek(toMediaTimeUs time: Int64) throws -> Int64 { guard ylf_seek(context, time) == YLFResultOK else { throw NativePlayerError(category: "seek", code: "seek", message: "seek failed") }; return time }
  func beginControlOperation(_ token: YlOpenCancellationToken?) {}
  func cancelInput() {}
  func close() { ylf_close(&context) }
  deinit { close() }
}
