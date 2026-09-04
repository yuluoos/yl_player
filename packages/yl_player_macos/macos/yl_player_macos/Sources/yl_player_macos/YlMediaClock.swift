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
  private var rate: Double = 1
  private var playing = false

  init(audioTime: (() -> YlRenderedAudioTime?)? = nil) {
    self.audioTime = audioTime
  }

  func anchorAudio(ptsUs: Int64, sampleTime: Int64) {
    lock.lock()
    mediaAnchorUs = max(0, ptsUs)
    audioSampleAnchor = sampleTime
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
    if let rendered = renderedAudioTime {
      audioSampleAnchor = rendered.sampleTime
    }
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
    if let rendered = renderedAudioTime {
      audioSampleAnchor = rendered.sampleTime
    }
    playing = false
    lock.unlock()
  }

  func seek(to positionUs: Int64) {
    lock.lock()
    mediaAnchorUs = max(0, positionUs)
    audioSampleAnchor = nil
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
    if let rendered = renderedAudioTime {
      audioSampleAnchor = rendered.sampleTime
    }
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
    if let audioSampleAnchor,
       let rendered = renderedAudioTime,
       rendered.sampleRate > 0 {
      let elapsedSamples = max(0, rendered.sampleTime - audioSampleAnchor)
      let elapsedUs = Double(elapsedSamples) * 1_000_000 / rendered.sampleRate
      return mediaAnchorUs + Int64(elapsedUs.rounded(.towardZero))
    }
    let elapsedHostUs = max(0, hostTimeUs - hostAnchorUs)
    return mediaAnchorUs + Int64((Double(elapsedHostUs) * rate).rounded(.towardZero))
  }
}
