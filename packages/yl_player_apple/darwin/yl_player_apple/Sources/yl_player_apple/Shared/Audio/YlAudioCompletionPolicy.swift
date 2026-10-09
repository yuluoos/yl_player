/// Stream-level eligibility only. The caller must derive source facts from
/// inspected media and separately validate actual PCM and output capabilities.
struct YlAudioCompletionContext {
  let enabled: Bool
  let platform: YlApplePlatform
  let localFiniteSeekable: Bool
  let hasBoundedPlan: Bool
  let codec: YlAudioCodec
  let sampleRate: Double
  let channels: Int
  let rate: Float
}

/// Internal selection reasons; never include source addresses or credentials.
enum YlAudioLegacyReason: Equatable {
  case disabled, platform, source, bounded, format, rate
}

enum YlAudioCompletionPolicy: Equatable {
  case legacy(YlAudioLegacyReason)
  case terminalCandidate

  static func select(_ context: YlAudioCompletionContext) -> Self {
    guard context.enabled else { return .legacy(.disabled) }
    guard context.platform == .macos else { return .legacy(.platform) }
    guard context.localFiniteSeekable else { return .legacy(.source) }
    guard !context.hasBoundedPlan else { return .legacy(.bounded) }
    guard context.codec == .aac, context.sampleRate == 48_000,
          context.channels == 2 else { return .legacy(.format) }
    guard context.rate == 1 else { return .legacy(.rate) }
    return .terminalCandidate
  }
}

/// The callback identifies either resource retirement or the playback boundary.
enum YlAudioOutputCompletionMode {
  case renderedResource
  case playedBack
}
