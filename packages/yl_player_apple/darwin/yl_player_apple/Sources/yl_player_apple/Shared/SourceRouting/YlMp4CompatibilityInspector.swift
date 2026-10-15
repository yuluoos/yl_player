import Foundation
import YlFFmpegBridge

/// Establishes codec incompatibility before AVPlayer commits a silent/frameless
/// MP4. Failure to inspect does not remove a source's existing native route.
enum YlMp4CompatibilityInspector {
  /// Older AVFoundation cannot honor an inspected MP4 MIME override. Use
  /// owned samples for mismatched names, retaining codec validation at prepare.
  static func needsOwnedMIMEFallback(_ source: YlAppleSourceDescriptor,
    supportsMIMEOverride: Bool) -> Bool {
    guard !supportsMIMEOverride, let url = source.url,
          source.formatHint == .mp4 else { return false }
    return !["mp4", "m4v", "m4a"].contains(url.pathExtension.lowercased())
  }

  static func requiresFallback(_ source: YlAppleSourceDescriptor,
    configuration: YlNetworkConfiguration, token: YlOpenCancellationToken) throws -> Bool {
    guard let url = source.url,
          [YlSourceFormat.mp4, .mov].contains(YlEngineRouter.resolvedFormat(source, url: url)) else { return false }
    try token.throwIfCancelled()
    let supportsMIMEOverride: Bool
    if #available(macOS 14.0, iOS 17.0, *) { supportsMIMEOverride = true }
    else { supportsMIMEOverride = false }
    if needsOwnedMIMEFallback(source, supportsMIMEOverride: supportsMIMEOverride) { return true }
    let recipe: YlFallbackSourceRecipe
    if url.isFileURL { recipe = .local(path: url.path, container: .mp4) }
    else {
      recipe = .network(request: .init(url: url, headers: source.headers,
        credentials: source.credentials, credentialContext: source.credentialContext,
        configuration: source.networkConfiguration.map(YlNetworkConfiguration.init(options:)) ?? configuration,
        mode: .randomAccessVOD, bufferScope: source.bufferScope), container: .mp4)
    }
    do {
      let media = try YlOpenedMedia(recipe: recipe, networkBufferBytes: 512 * 1024,
        onSourceCreated: { bytes in token.onCancel { bytes.cancel() } })
      defer { media.close() }
      try token.throwIfCancelled()
      guard let context = media.context else { return false }
      return ylf_mp4_requires_fallback(context)
    } catch {
      try token.throwIfCancelled()
      return false
    }
  }
}
