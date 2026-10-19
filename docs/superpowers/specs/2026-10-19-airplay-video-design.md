# AirPlay video

User authorization: implement AirPlay video, including the discussed H.264/AAC
remux bridge for custom-source playback. Native rendering alone is not AirPlay.

## Contract

- Opt in per load with `YlLoadOptions(airPlay: true)`. Existing loads retain
  their local playback policy. Unsupported adapters reject explicitly.
- Direct HTTP(S) HLS/MP4/MOV without custom credentials uses AVPlayer external
  playback. An explicitly opted-in compatible finite local/HTTP source can use
  bounded H.264/AAC passthrough to HLS. No arbitrary codec transcoding.
- Reject DRM, managed networking guarantees, bounded playback buffers, required
  hardware decoding and video constraints rather than silently weakening them.
- Expose a system route picker and session-scoped external-playback state.
  Device selection remains the user's system UI action.
- Preserve the existing load identity, rollback, cancellation and state/reply
  barrier. Negotiate an optional versioned channel without changing schema 7.
- External playback must not fabricate a local first frame or trigger a local
  frame starvation timeout. An opted-in session can continue in background only
  when host background-audio configuration is present; interruptions still apply.
- Remux output has bounded disk/time/request resources, capability URLs, safe
  HTTP access and cleanup. Receiver reachability is a physical-device criterion.
- iOS 15/macOS 12 floors remain. App source, credentials and private paths are
  not included in diagnostic messages.

## Acceptance

Automated Dart contract/widget tests, native route/lifecycle tests, real remux
fixture output and AVPlayer consumption, Apple builds and relevant regressions.
Physical AirPlay and CarPlay are explicitly unverified until exercised against
actual receivers. CarPlay browsing/entitlements are a separate application layer.
