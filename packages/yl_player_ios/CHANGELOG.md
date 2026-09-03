## 0.1.0-dev.1

- Add endorsed iOS federated registration.
- Set the minimum iOS version to 15.0 for CocoaPods and Swift Package Manager.
- Add AVPlayer playback over AVPlayerItemVideoOutput and Flutter Texture for
  HLS, supported progressive media, and local files.
- Add live/DVR state, audio selection, quality limits, metrics, and structured
  errors.
- Reject HTTP-FLV explicitly until the native fallback is bundled.
- Reject custom-header sources rather than relying on undocumented AVFoundation
  request options.
- Add source-generation isolation, one-active-decoder arbitration, playback
  audio-session setup, and background/memory-pressure decoder release.
