import Foundation

/// All access is serialized by the renderer's operations lock. Native callbacks
/// carry tickets only; they never inspect or release an owner on the audio thread.
final class YlAudioTerminalState {
  final class Resource {
    let epoch: UInt64
    let ordinal: UInt64
    let ptsUs: Int64
    let durationUs: Int64
    let bytes: Int
    var buffer: YlScheduledAudioBuffer?
    var mode: YlAudioOutputCompletionMode?
    init(_ buffer: YlScheduledAudioBuffer, epoch: UInt64, ordinal: UInt64) {
      self.epoch = epoch
      self.ordinal = ordinal
      self.ptsUs = buffer.ptsUs
      self.durationUs = max(0, buffer.durationUs)
      self.bytes = max(max(0, buffer.byteCount), buffer.reservation?.bytes ?? 0)
      self.buffer = buffer
    }
    func retire() {
      let reservation = buffer?.reservation
      buffer = nil
      reservation?.release()
    }
    deinit { retire() }
  }

  private let epoch: UInt64
  init(epoch: UInt64) { self.epoch = epoch }

  private var resources: [UInt64: Resource] = [:]
  private var tail: Resource?
  private var ordinal: UInt64 = 0
  private var lastPlayedBack = false
  private var waitStartedUs: UInt64?
  private var lastObservationUs: UInt64?
  private(set) var isLegacy = false
  private(set) var inputFinished = false
  var count: Int { resources.count }
  var bytes: Int { resources.values.reduce(0) { $0 + $1.bytes } }
  var durationUs: Int64 { resources.values.reduce(0) { $0 + $1.durationUs } }
  var onlyHeldTail: Bool { tail != nil && count == 1 }
  var pendingPlayback: Bool { !resources.isEmpty || (ordinal != 0 && !lastPlayedBack) }

  func accept(_ buffer: YlScheduledAudioBuffer) -> [Resource] {
    precondition(!inputFinished && ordinal < UInt64.max)
    var submissions: [Resource] = []
    if let previous = tail {
      previous.mode = .renderedResource
      submissions.append(previous)
    }
    ordinal += 1
    let resource = Resource(buffer, epoch: epoch, ordinal: ordinal)
    resources[ordinal] = resource
    lastPlayedBack = false
    waitStartedUs = nil
    if isLegacy {
      resource.mode = .playedBack
      submissions.append(resource)
      tail = nil
    } else { tail = resource }
    return submissions
  }

  func abandon() -> [Resource] {
    guard !isLegacy else { return [] }
    isLegacy = true
    waitStartedUs = nil
    return submitTail()
  }

  func finishInput() -> [Resource] {
    guard !inputFinished else { return [] }
    inputFinished = true
    return submitTail()
  }

  private func submitTail() -> [Resource] {
    guard let held = tail else { return [] }
    tail = nil
    held.mode = .playedBack
    return [held]
  }

  func observe(playing: Bool, nowUs: UInt64) -> [Resource] {
    guard !inputFinished, !isLegacy else { return [] }
    if let last = lastObservationUs, nowUs < last { return abandon() }
    lastObservationUs = nowUs
    guard playing, onlyHeldTail else { waitStartedUs = nil; return [] }
    if waitStartedUs == nil { waitStartedUs = nowUs }
    return nowUs - waitStartedUs! >= 100_000 ? abandon() : []
  }

  func pause() { waitStartedUs = nil }

  func complete(_ ticket: UInt64, mode: YlAudioOutputCompletionMode) -> Resource? {
    guard let resource = resources[ticket], resource.mode == mode else { return nil }
    resources.removeValue(forKey: ticket)
    if mode == .playedBack, ticket == ordinal { lastPlayedBack = true }
    resource.retire()
    return resource
  }

  /// The renderer fences callbacks first, then stops native output, then calls this.
  func retireAfterStop() {
    tail = nil
    resources.values.forEach { $0.retire() }
    resources.removeAll()
  }
}
