## 0.3.0-dev.1

- Add the public AirPlay button, availability stream, and route-picker control
  for Apple playback.
- Add RTMPS live source support and external-playback lifecycle handling.

## 0.2.0-dev.2

- Preserve explicit Android audio content selection across reordered DASH Periods
  and session restoration. Publish semantic group identities, reject ambiguous
  groups, and report missing selected content as `track.not_found`.
- Add stable audio identities and Apple DASH multi-audio selection for up to 16
  AAC-LC AdaptationSets, retaining the selected track across quality replacement
  and same-session restoration. Reject ambiguous or changing Period audio sets;
  clarify audio-track API identity and acknowledgment semantics.
- Preserve bounded BCP 47 `elng` metadata for embedded MP4 tx3g/wvtt/stpp subtitles, including fragmented/hybrid resources; retain track identity and atomic managed loading.
- Restore up to four ordered Matroska subtitle compression stages, filtering
  block/private scopes independently and retaining intermediate-byte budgets.
  Clarify the API boundary; Next scopes, encryption and WebM remain unsupported.
- Include tx3g font/bitrate configuration and sample style boxes in the shared
  MP4 structural budget, preserving selected subtitles on discovery overflow.
  Clarify API limits and correct support-document formatting.
- Count MP4 WebVTT configuration, sample and cue boxes plus TTML configuration
  boxes against the shared structural limit across tracks and fragments.
  Preserve the selected subtitle catalog on overflow and clarify API limits.
- Restore compressed Matroska CodecPrivate for private-only or combined
  block/private scope before codec validation. Preserve stored/restored header
  budgets across empty tracks and catalog updates, and clarify the API scope.
- Restore Matroska subtitle blocks with single block-only zlib or header
  stripping before existing text/bitmap decoding. Enforce strict zlib framing,
  output limits and persisted stored/restored byte budgets; document supported
  compression in controller and discovery APIs.
- Add file and managed HTTP Matroska embedded VobSub discovery, selection and
  bitmap rendering from CodecPrivate/raw SPU, preserving container timing,
  DVD control/alpha updates and shared bitmap budgets. Complete controller and
  discovery API comments for supported network containers and bitmap subtitles.
- Add Matroska embedded PGS bitmap discovery and rendering for files and managed
  HTTP, preserving container timing, duration caps and shared bitmap budgets.
  Clarify WebM and per-container text/PGS support in the discovery API docs.
- Add file and managed HTTP WebM embedded WebVTT discovery, retaining TrackUID
  selection and shared rendering; verify explicit WebM/Matroska format declarations
  against the container DocType and keep metadata tracks out of subtitle overlays.
- Add bounded Matroska WebVTT subtitle discovery for S_TEXT/WEBVTT and
  D_WEBVTT/SUBTITLES/CAPTIONS, with cue ID/placement, raw metadata accounting,
  existing managed Range policy and shared subtitle rendering/lifecycle.
- Support hybrid MP4 subtitle tracks combining initial sample tables with later
  fragments for tx3g, WebVTT and TTML. Preserve per-track decode continuity and
  validate subtitle byte extents and budgets across both portions.

- Add single-resource fragmented MP4 tx3g (mov_text) subtitle discovery and
  selection with existing literal styled-text rendering, fragment timing and
  managed ranges; validate with an independently muxed FFmpeg fixture.

- Add single-resource fragmented MP4 WebVTT/TTML subtitle discovery, Track ID
  selection and existing text/region rendering. Resolve fragment sample defaults,
  offsets and composition timing through the existing bounded managed Range path.

- Add local and HTTP(S) non-fragmented MP4 TTML (stpp) subtitle discovery,
  Track ID selection and existing TTML styled-text/region rendering. Resolve
  document composition times within sample/edit intervals, isolate document
  regions and account raw XML in the shared catalog budget. Reuse managed ranges.

- Add local and HTTP(S) non-fragmented MP4 WebVTT (wvtt) embedded subtitles
  with Track ID selection, sample-timed cues, basic markup and horizontal
  align/position rendering. Reuse managed conditional ranges and cancellation;
  enforce bounded boxes, payloads and cross-track cue totals before publication.

- Add local and HTTP(S) non-fragmented MP4 tx3g embedded subtitle discovery,
  Track ID selection and basic styled text rendering with sample-table/edit-list
  timing. Network discovery reuses managed conditional ranges and scan budgets;
  unsupported codecs/effects and malformed indexes preserve the old catalog.

- Add HTTP(S) Matroska embedded UTF8/ASS/SSA discovery through managed range
  reads, with strong ETag/length consistency, If-Match, scan-wide retry/redirect
  and credential rules, bounded caching and cancellation. Requires single-range
  206 responses; network failures preserve the prior subtitle catalog.

- Add opt-in local Matroska embedded UTF8/ASS/SSA discovery from the committed
  source, stable TrackUID selection and shared media-time rendering. External
  and embedded catalogs preserve one another and share resource budgets.
  Network/other containers/native callbacks remain outside this slice.

- Add opt-in external VobSub DVD subtitles using explicit .sub/.idx pairs,
  managed loading/cancellation, index language selection, PS/SPU assembly,
  two-field RLE and timed palette/contrast/position changes. Shares bounded
  RGBA storage and active-image rendering with PGS; advanced DVD/HD effects
  and native-device acceptance remain outside this subset.

- Add opt-in external PGS/SUP bitmap subtitles through the managed loader,
  with bounded RLE/palette decoding, cropped/windowed composition, palette
  updates and media-time clearing. Active images use a bounded asynchronous
  decode queue with late-result disposal; full disc/native-device subtitle
  qualification and VobSub remain outside this subset.

- Add opt-in external ASS/SSA UTF-8 text subtitles through the managed loader,
  with bounded styles, outline/shadow, script-space positioning/layers and
  media-clock movement/fades. Supports explicit WrapStyle 1/2; unsupported
  effects and attachments fail explicitly. This is a Flutter text subset,
  not full libass or native-device subtitle qualification.
- Add external TTML text loading/rendering with bounded namespace-aware XML,
  media timing, referenced basic styles and clipped percentage regions, using
  the existing file/managed HTTP and atomic subtitle catalog pipeline.
- Enforce managed HTTP policy for external subtitles: per-hop header and body
  inactivity timeouts, bounded retries/Retry-After, shared redirect budgets and
  cancellable backoff with permanent cross-origin credential stripping.
- Add opt-in external SRT/WebVTT loading from bounded files and HTTP(S), atomic
  catalog replacement/cancellation, and media-position-driven text overlays in
  `YlPlayerView`. Enable with `create(enableTextSubtitles: true)`. Advanced
  subtitle formats and protected-video overlays remain unsupported.
- Add subtitle source/catalog values and optional session commands for replacing
  external subtitles, selection/off, and signed time offsets. Current native
  adapters explicitly reject these commands until rendering support is added.
- Expose media-clock progress metrics and update the synchronized endorsed
  Android and Apple implementations with live-playback stability fixes.

## 0.2.0-dev.1

- Replace implicit construction/open with asynchronous Player creation, source
  assessment, committed Session handles, and separate Ready/First Frame futures.
- Add stale-session fencing, reusable Stop, idempotent Dispose, correlated
  state/events, safe structured failures, and authoritative video geometry.
- Add explicit player/load options for network, buffer, decoder, audio ownership,
  autoplay, start position, and video constraints.
- Endorse the consolidated Android and Apple v0.2 implementations and remove the
  legacy protocol bridge and split Apple packages.
- Publish the v0.2 migration, support, policy, diagnostics, and runnable lifecycle
  documentation. Final multi-platform acceptance remains pending.
- Add transport-size, measured-cadence, package-archive, and publication dry-run
  gates for the v0.2 release candidate.

## 0.1.0-dev.1

- Define the app-facing controller and texture-only player view.
- Endorse the Android and iOS implementation packages.
- Add a runnable public API example.
- Add functional Android Media3 and iOS AVPlayer endorsed main paths.
- Bundle an experimental iOS H.264/H.265 + AAC Matroska fallback for local files
  and HTTP/HTTPS VOD; hardware decode, physical-device playback, and endurance
  acceptance remain release gates.
- Add URLSession-backed custom AVIO streaming with bounded 4/8/16 MiB network
  cache profiles, Range seek, sequential HTTP 200 playback, retry, redirects,
  request headers, cancellation, and foreground reconstruction.
- Add experimental iOS HTTP/HTTPS-FLV live playback for hardware H.264/H.265
  with AAC-LC or MP3, non-seekable state, keyframe-gated bounded reconnects, and
  caller request headers.
- Add iOS HLS custom headers across manifests, AES keys, initialization/media
  resources, with same-origin-only credentials and a cancellable loopback media
  proxy that avoids undocumented AVFoundation header options.
- Add bounded iOS AVPlayer reconnects for direct live HLS and sanitized
  HLS error-log diagnostics for terminal failures.
- Add the endorsed macOS 12+ implementation with AVPlayer HLS/progressive
  playback and hardware-only VideoToolbox fallbacks for local/network MKV and
  HTTP/HTTPS-FLV live playback.
- Add macOS AAC/MP3 fallback audio, bounded network buffering and reconnects,
  authenticated HLS origin protection, lifecycle cleanup, universal
  `arm64`/`x86_64` artifacts, and native/integration CI gates.
- Verify macOS runtime on Apple Silicon and compile/link plus Rosetta smoke for
  Intel; physical Intel hardware runtime remains unverified.
- Treat custom `maxBufferBytes` as the total managed-media budget for network
  bytes, scheduled PCM, and bounded in-flight encoded video; do not persist
  media.
- Enforce one macOS VideoToolbox fallback decoder at a time with quiesce/rollback
  replacement, one-shot terminal teardown, origin-bound redirect credentials,
  and sanitized AVPlayer errors.
- Keep iOS network MKV live and other remote fallback containers,
  non-AAC MKV audio, subtitles, and DRM unsupported.
- Keep Dart resource teardown idempotent even when native disposal reports an
  error.
- Add Android automatic device tiers, hardware-only video selection,
  source-specific bounded buffers, downgrade-only health adaptation, and
  low-memory TV lifecycle recovery.
- Expose nullable Android device-tier, target-buffer, adaptive-downgrade,
  Surface-rebuild, and selected-video-bitrate metrics.
- Keep Android physical-device endurance validation deferred for the Android
  7.0 / 1.5 GB RAM / 32-bit ARM reference TVBox.
