# AAC 5.1 startup failure — 2026-09-20

## Evidence and cause

The reported macOS TVS open failed with `decoder.audio_aac_unsupported`.
The separate HTTP 501 response identifies `danmuPush` as unsupported; it is not
an audio-decoder error.

A bounded 2 MiB prefix fetched through the user's running local proxy contains
HEVC video, E-AC-3 5.1, AAC-LC 48 kHz 5.1 (ASC `11 b0`), and AAC-LC stereo.
The production fallback selects AAC stream 2, six channels, 48 kHz.
No media, proxy URLs, cookies, or credentials are included in this repository.

The compressed input and PCM output used the AVAudioFormat initializers that
only accept one or two channels without a channel layout. A native probe
confirmed AAC FormatInfo succeeds, but both six-channel formats return nil.
Apple documents the layout requirement in AVAudioFormat.h and provides
[ChannelLayoutFromESDS](https://developer.apple.com/documentation/audiotoolbox/kaudioformatproperty_channellayoutfromesds)
to recover the encoded layout.

## Change

For multichannel AAC, derive the layout from the ASC wrapped as ESDS; validate
that its channel count matches the stream. Preserve that layout in compressed
input, decoded PCM, and the system audio output graph. Do not guess a speaker
order from the channel count. Keep the existing mono/stereo and DTS paths.

## Verification

- Two new macOS regression cases failed before the change: real AAC 5.1
  conversion and real output configuration / subsequent stereo reconfiguration.
- After the change, macOS audio tests: 12 passed, zero failures/skips.
- iOS 27 simulator audio tests: 21 passed, zero failures/skips.
- Additional invalid/mismatched AAC configuration and DTS center-channel/reset
  tests: 2 passed on each platform, zero failures/skips.
- Original media probe, using the built production module: selected stream 2,
  48 kHz / six channels; decoded 48,128 PCM frames (1,155,072 bytes), retaining
  AAC 5.1 layout; real system output configured successfully.
- TVS macOS Debug consumer build succeeded with ad-hoc signing; bundle signature
  verification passed. Built app: `/private/tmp/yl-tvs-macos-hdr/Build/Products/Debug/tvs.app`.
- Current test inventory: iOS 441 / macOS 357; canonical fixture copies and
  production source parity checks passed. Inventory counts are not run counts.

These checks cover startup, decoding, layout propagation, and audio regressions.
They do not establish physical surround-speaker routing or long-duration playback.
