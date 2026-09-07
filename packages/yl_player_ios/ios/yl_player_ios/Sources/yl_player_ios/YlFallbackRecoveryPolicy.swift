import Foundation

struct YlFallbackLifecycleTransaction {
  let pauseClock: () throws -> Void
  let advanceGeneration: () throws -> UInt64
  let stopDemux: () throws -> Void
  let clearBuffers: (UInt64) throws -> Void
  let seekDemux: (Int64) throws -> Void
  let resetAudio: (UInt64) throws -> Void
  let recreateVideo: (UInt64) throws -> Void
  let suppressFramesBefore: (Int64) throws -> Void
  let restartDemux: () throws -> Void

  func seek(toUs targetUs: Int64) throws {
    try pauseClock()
    let generation = try advanceGeneration()
    try stopDemux()
    try clearBuffers(generation)
    try seekDemux(targetUs)
    try resetAudio(generation)
    try recreateVideo(generation)
    try suppressFramesBefore(targetUs)
    try restartDemux()
  }
}

struct YlFallbackTeardownTransaction {
  let cancelInput: () -> Void
  let joinAndRelease: () -> Void

  func run() {
    cancelInput()
    joinAndRelease()
  }
}

struct YlFallbackSeekPolicy {
  let isSeekable: Bool
  let perform: (Int64) throws -> Void

  func seek(toUs targetUs: Int64) throws {
    guard isSeekable else {
      throw NativePlayerError(
        category: "network",
        code: "network.range_not_supported",
        message: "This network source does not support random access."
      )
    }
    try perform(targetUs)
  }
}

struct YlFallbackMediaPolicy: Equatable {
  let container: YlFallbackContainer
  let isLive: Bool
  let isSeekable: Bool
  let requiresInitialVideoKeyframe: Bool

  init(container: YlFallbackContainer, sourceSupportsRandomAccess: Bool) {
    self.container = container
    switch container {
    case .matroska:
      isLive = false
      isSeekable = sourceSupportsRandomAccess
      requiresInitialVideoKeyframe = false
    case .flv:
      isLive = true
      isSeekable = false
      requiresInitialVideoKeyframe = true
    }
  }

  func durationMs(mediaDurationUs: Int64) -> Int64? {
    guard !isLive, mediaDurationUs > 0 else { return nil }
    return mediaDurationUs / 1_000
  }
}

struct YlInitialKeyframeGate {
  private(set) var isOpen = false

  mutating func accepts(isVideo: Bool, isKeyframe: Bool) -> Bool {
    if isOpen || !isVideo { return isOpen }
    if isKeyframe { isOpen = true }
    return isOpen
  }

  mutating func reset() {
    isOpen = false
  }
}

enum YlFallbackCommandPolicy {
  static func requiresBackgroundExecution(
    isNetwork: Bool,
    isActive: Bool,
    name: String
  ) -> Bool {
    isNetwork && isActive && (name == "seekTo" || name == "selectAudioTrack")
  }
}

enum YlFallbackRetryEvent {
  static func envelope(
    playerId: Int64,
    attempt: Int,
    delayMs: Int64,
    error: NativePlayerError
  ) -> [String: Any?] {
    [
      "playerId": playerId,
      "type": "retry",
      "attempt": attempt,
      "delayMs": delayMs,
      "error": errorMap(
        category: error.category,
        code: error.code,
        message: error.message,
        diagnostic: error.diagnostic
      ),
    ]
  }
}

struct YlFallbackResumeState: Equatable {
  let positionUs: Int64
  let selectedAudioStreamIndex: Int32?
  let shouldPlay: Bool
}

enum YlFallbackReactivationPolicy {
  static func resolve(
    isSeekable: Bool,
    savedPositionUs: Int64,
    selectedAudioStreamIndex: Int32?,
    shouldPlay: Bool
  ) -> YlFallbackResumeState {
    YlFallbackResumeState(
      positionUs: isSeekable ? max(0, savedPositionUs) : 0,
      selectedAudioStreamIndex: selectedAudioStreamIndex,
      shouldPlay: isSeekable && shouldPlay
    )
  }
}

struct YlFallbackReplacementGenerations: Equatable {
  let videoGeneration: UInt64
  let audioGeneration: UInt64
}

enum YlFallbackReplacementGenerationPolicy {
  static func quiesce(
    videoGeneration: UInt64,
    audioGeneration: UInt64
  ) -> YlFallbackReplacementGenerations {
    // Decoded video callbacks can still arrive after VideoToolbox is paused, so
    // invalidate them. The retained audio renderer, however, remains configured
    // for its current generation and must accept the first packet after rollback.
    YlFallbackReplacementGenerations(
      videoGeneration: videoGeneration &+ 1,
      audioGeneration: audioGeneration
    )
  }
}
