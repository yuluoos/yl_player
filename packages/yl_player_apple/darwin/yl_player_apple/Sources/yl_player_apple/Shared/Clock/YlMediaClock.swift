import Foundation

struct YlRenderedAudioTime: Equatable {
  let sampleTime: Int64
  let sampleRate: Double
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

  init(audioTime: (() -> YlRenderedAudioTime?)? = nil) {
    self.audioTime = audioTime
  }

  func anchorAudio(ptsUs: Int64, sampleTime: Int64) {
    lock.lock()
    mediaAnchorUs = max(0, ptsUs)
    audioSampleAnchor = sampleTime
    lastAudioPosition = nil
    lock.unlock()
  }

  func play(atHostTimeUs hostTimeUs: Int64) {
    let renderedAudioTime = audioTime?()
    lock.lock()
    guard !playing else {
      lock.unlock()
      return
    }
    hostAnchorUs = hostTimeUs
    audioSampleAnchor = renderedAudioTime?.sampleTime
    lastAudioPosition = nil
    playing = true
    lock.unlock()
  }

  func pause(atHostTimeUs hostTimeUs: Int64) {
    let renderedAudioTime = audioTime?()
    lock.lock()
    guard playing else {
      lock.unlock()
      return
    }
    mediaAnchorUs = positionLocked(
      atHostTimeUs: hostTimeUs,
      renderedAudioTime: renderedAudioTime
    )
    hostAnchorUs = hostTimeUs
    audioSampleAnchor = renderedAudioTime?.sampleTime
    lastAudioPosition = nil
    playing = false
    lock.unlock()
  }

  func seek(to positionUs: Int64) {
    lock.lock()
    mediaAnchorUs = max(0, positionUs)
    audioSampleAnchor = nil
    lastAudioPosition = nil
    lock.unlock()
  }

  func setRate(_ value: Double, atHostTimeUs hostTimeUs: Int64) {
    let renderedAudioTime = audioTime?()
    lock.lock()
    let position = positionLocked(
      atHostTimeUs: hostTimeUs,
      renderedAudioTime: renderedAudioTime
    )
    mediaAnchorUs = position
    hostAnchorUs = hostTimeUs
    audioSampleAnchor = renderedAudioTime?.sampleTime
    lastAudioPosition = nil
    rate = min(max(value, 0.25), 4)
    lock.unlock()
  }

  func position(atHostTimeUs hostTimeUs: Int64) -> Int64 {
    let renderedAudioTime = audioTime?()
    lock.lock()
    defer { lock.unlock() }
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
