import Foundation

struct YlRenderedAudioTime: Equatable {
  let sampleTime: Int64
  let sampleRate: Double
  let hostTimeUs: Int64?
  init(sampleTime: Int64, sampleRate: Double, hostTimeUs: Int64? = nil) {
    self.sampleTime = sampleTime; self.sampleRate = sampleRate; self.hostTimeUs = hostTimeUs
  }
}

final class YlMediaClock {
  private let lock = NSLock()
  private let audioTime: (() -> YlRenderedAudioTime?)?
  private var mediaAnchorUs: Int64 = 0
  private var hostAnchorUs: Int64 = 0
  private var audioSampleAnchor: Int64?
  private var lastAudioPosition: (positionUs: Int64, hostTimeUs: Int64)?
  private var rate: Double = 1
  private var playing = false
  private var paused = false
  private var isolated: YlIsolatedAudioClock?
  private var audioGeneration: UInt64 = 0

  init(audioTime: (() -> YlRenderedAudioTime?)? = nil) {
    self.audioTime = audioTime
  }

  func enableIsolatedAudioClock(read: @escaping (UInt64) -> YlAudioClockObservation, generation: UInt64) {
    lock.withLock {
      guard isolated == nil else { return }
      audioGeneration = generation
      isolated = YlIsolatedAudioClock(read: read, hostTimeUs: {
        Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)
      })
      configureIsolatedLocked()
    }
  }
  private func configureIsolatedLocked() {
    isolated?.configure(generation: audioGeneration, positionUs: mediaAnchorUs, rate: rate, playing: playing)
  }
  func invalidateIsolatedAudioClock() {
    lock.withLock {
      guard let isolated else { return }
      mediaAnchorUs = isolated.snapshot(atHostTimeUs: Int64(ProcessInfo.processInfo.systemUptime * 1_000_000)).positionUs
      isolated.invalidate()
    }
  }
  func setAudioClockGeneration(_ generation: UInt64) {
    lock.withLock { audioGeneration = generation; isolated?.invalidate() }
  }
  func stopIsolatedAudioClock() { lock.withLock { isolated?.stop() } }
  var isolatedAudioClockStatistics: YlIsolatedAudioClockStatistics? {
    lock.withLock { isolated?.statistics }
  }
  private var isolatedClock: YlIsolatedAudioClock? { lock.withLock { isolated } }

  func anchorAudio(ptsUs: Int64, sampleTime: Int64) {
    anchorAudio(ptsUs: ptsUs, sampleTime: sampleTime, preservingPause: false)
  }

  func anchorSubmittedAudio(ptsUs: Int64, sampleTime: Int64) {
    anchorAudio(ptsUs: ptsUs, sampleTime: sampleTime, preservingPause: true)
  }

  private func anchorAudio(ptsUs: Int64, sampleTime: Int64, preservingPause: Bool) {
    lock.lock()
    defer { lock.unlock() }
    // A submission notification can arrive after pause froze the position.
    // Resume samples the renderer again; replacing this position would lose
    // the audio already consumed before pause. Initial/seek anchors still apply.
    guard !preservingPause || !paused else { return }
    mediaAnchorUs = max(0, ptsUs)
    audioSampleAnchor = sampleTime
    lastAudioPosition = nil
  }

  func play(atHostTimeUs hostTimeUs: Int64) {
    let renderedAudioTime = isolatedClock == nil ? audioTime?() : nil
    lock.lock()
    guard !playing || isolated != nil else {
      lock.unlock()
      return
    }
    hostAnchorUs = hostTimeUs
    audioSampleAnchor = renderedAudioTime?.sampleTime
    lastAudioPosition = nil
    playing = true
    paused = false
    configureIsolatedLocked()
    lock.unlock()
  }

  func pause(atHostTimeUs hostTimeUs: Int64) {
    let renderedAudioTime = isolatedClock == nil ? audioTime?() : nil
    lock.lock()
    guard playing else {
      lock.unlock()
      return
    }
    mediaAnchorUs = isolated?.snapshot(atHostTimeUs: hostTimeUs).positionUs ?? positionLocked(
      atHostTimeUs: hostTimeUs,
      renderedAudioTime: renderedAudioTime
    )
    hostAnchorUs = hostTimeUs
    audioSampleAnchor = renderedAudioTime?.sampleTime
    lastAudioPosition = nil
    playing = false
    paused = true
    configureIsolatedLocked()
    lock.unlock()
  }

  func seek(to positionUs: Int64) {
    lock.lock()
    mediaAnchorUs = max(0, positionUs)
    paused = false
    audioSampleAnchor = nil
    lastAudioPosition = nil
    configureIsolatedLocked()
    lock.unlock()
  }

  func setRate(_ value: Double, atHostTimeUs hostTimeUs: Int64) {
    let renderedAudioTime = isolatedClock == nil ? audioTime?() : nil
    lock.lock()
    let position = isolated?.snapshot(atHostTimeUs: hostTimeUs).positionUs ?? positionLocked(
      atHostTimeUs: hostTimeUs,
      renderedAudioTime: renderedAudioTime
    )
    mediaAnchorUs = position
    hostAnchorUs = hostTimeUs
    audioSampleAnchor = renderedAudioTime?.sampleTime
    lastAudioPosition = nil
    rate = min(max(value, 0.25), 4)
    configureIsolatedLocked()
    lock.unlock()
  }

  func presentationSnapshot(atHostTimeUs hostTimeUs: Int64) -> YlPresentationClockSnapshot {
    let renderedAudioTime = isolatedClock == nil ? audioTime?() : nil
    lock.lock()
    defer { lock.unlock() }
    if let isolated { return isolated.snapshot(atHostTimeUs: hostTimeUs) }
    return .init(positionUs: positionLocked(atHostTimeUs: hostTimeUs, renderedAudioTime: renderedAudioTime),
      hostTimeUs: hostTimeUs, rate: rate, playing: playing)
  }

  func position(atHostTimeUs hostTimeUs: Int64) -> Int64 {
    let renderedAudioTime = isolatedClock == nil ? audioTime?() : nil
    lock.lock()
    defer { lock.unlock() }
    if let isolated { return isolated.snapshot(atHostTimeUs: hostTimeUs).positionUs }
    return positionLocked(
      atHostTimeUs: hostTimeUs,
      renderedAudioTime: renderedAudioTime
    )
  }

  private func positionLocked(
    atHostTimeUs hostTimeUs: Int64,
    renderedAudioTime: YlRenderedAudioTime?
  ) -> Int64 {
    guard playing else { return mediaAnchorUs }
    if let rendered = renderedAudioTime, rendered.sampleRate > 0 {
      let position: Int64
      if let audioSampleAnchor {
        let elapsedSamples = max(0, rendered.sampleTime - audioSampleAnchor)
        let elapsedUs = Double(elapsedSamples) * 1_000_000
          / rendered.sampleRate
        position = mediaAnchorUs + Int64(elapsedUs.rounded(.towardZero))
      } else {
        position = hostPosition(atHostTimeUs: hostTimeUs)
        mediaAnchorUs = position
        hostAnchorUs = hostTimeUs
        audioSampleAnchor = rendered.sampleTime
      }
      lastAudioPosition = (position, hostTimeUs)
      return position
    }
    if let lastAudioPosition {
      // Audio may end before video. Continue from its last observed position,
      // excluding any earlier wall-clock time spent waiting for audio data.
      mediaAnchorUs = lastAudioPosition.positionUs
      hostAnchorUs = lastAudioPosition.hostTimeUs
      self.lastAudioPosition = nil
    }
    audioSampleAnchor = nil
    return hostPosition(atHostTimeUs: hostTimeUs)
  }

  private func hostPosition(atHostTimeUs hostTimeUs: Int64) -> Int64 {
    let elapsedHostUs = max(0, hostTimeUs - hostAnchorUs)
    return mediaAnchorUs + Int64((Double(elapsedHostUs) * rate).rounded(.towardZero))
  }
}
