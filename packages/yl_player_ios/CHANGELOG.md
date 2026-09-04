## 0.1.0-dev.1

- Add endorsed iOS federated registration.
- Set the minimum iOS version to 15.0 for CocoaPods and Swift Package Manager.
- Add AVPlayer playback over AVPlayerItemVideoOutput and Flutter Texture for
  HLS, supported progressive media, and local files.
- Add live/DVR state, audio selection, quality limits, metrics, and structured
  errors.
- Add a bounded, experimental local and HTTP/HTTPS VOD Matroska fallback using
  FFmpeg custom AVIO demux, required-hardware VideoToolbox decode, and native
  AAC rendering.
- Add 4/8/16 MiB network cache profiles, custom managed-media budgets, HTTP
  Range seek, sequential playback, timeout/retry, validator-aware reconnect,
  redirect credential stripping, cancellation, and lifecycle reconstruction.
- Accept custom headers on the network Matroska fallback while continuing to
  reject them on AVPlayer routes rather than using undocumented request keys.
- Add HTTP/HTTPS-FLV live playback for hardware H.264/H.265 plus AAC-LC or MP3,
  including sequential input, non-seekable semantics, keyframe-gated pipeline
  reconstruction, bounded retry events, and cancellation.
- Add HLS custom headers for manifests, AES keys, and media/init resources with
  same-origin credential filtering, manifest rewriting, and a lifecycle-owned
  loopback media proxy.
- Keep network MKV live and other remote fallback containers,
  non-AAC audio, subtitles, DRM, and persistent cache explicitly unsupported.
- Add source-generation isolation, one-active-decoder arbitration, playback
  audio-session setup, and background/memory-pressure decoder release.
- Decode the cross-platform Android diagnostic fields as nullable values while
  leaving iOS behavior unchanged.
