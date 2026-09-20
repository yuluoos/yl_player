# Dolby audio recognition and Dolby Vision profile diagnostics

## Reproduction

The new report contains two independent opening failures:

- Quark: `decoder.audio_aac_unsupported`. A bounded prefix contains HEVC and
  E-AC-3 48 kHz / 5.1 audio, with no AAC track. The bridge mapped E-AC-3 to
  unsupported; the fallback rejected all audio using an AAC-specific code.
- Baidu: `decoder.video_configuration_invalid`. Its valid Dolby Vision record
  describes Profile 7, level 6, RPU + base + enhancement layer, compatibility 6.
  The current renderer supports Profile 5, so this is a capability limit rather
  than corrupt HEVC configuration.

Source prefixes and all source URLs remain outside the repository.

## Earlier audio/profile-diagnostics changes

- Identify AC-3 and E-AC-3 in the native bridge. Enable the AC3 parser to recover
  sample timing and native speaker masks; their FFmpeg decoders remain disabled.
- Pass native speaker masks through initial, reconnect, and track configurations.
  Use CoreAudio AC-3/E-AC-3 decoding and explicit speaker descriptions for PCM
  and output. E-AC-3 supports variable packet frame counts; Dolby syncframes do
  not use the macOS AAC look-ahead batching policy.
- Use codec-specific errors or `decoder.audio_unsupported` for unknown audio.
- Classify supported-structure but unimplemented DV Profile 7/8 separately as
  `decoder.dolby_vision_unsupported`. Malformed configuration still fails as
  `decoder.video_configuration_invalid`. No video-format downgrade was added.

## Earlier audio/profile-diagnostics verification

- Two new real-converter/output macOS tests failed before implementation.
- macOS: 22 selected tests passed; iOS 27 simulator: 31 selected tests passed.
  Zero failures or skips. Coverage includes center-only AC-3/E-AC-3 PCM energy,
  six-channel buffer sizing, reset, byte counts, AAC reconfiguration, missing or
  mismatched masks, AAC/DTS regressions, reconnect metadata, and public errors.
- Actual Quark prefix through the final production module: selected stream 1,
  E-AC-3, 48 kHz, six channels, mask `0x60f`; 24,288 PCM frames / 582,912 bytes
  decoded; real system output configured successfully.
- Actual Baidu prefix through the final production module: public error is
  `decoder.dolby_vision_unsupported`, with no downgrade.
- Native bridge tests: 46 audio checks and 35 video metadata checks passed.
- All five architectures rebuilt from signed pinned FFmpeg source; independent
  rebuild matched all 18 canonical artifact entries byte-for-byte. Contract and
  immutable verifier checks passed, including foreign-host verification and
  corruption discrimination.
- TVS macOS signed Debug build succeeded and its bundle signature verified;
  build log: `/private/tmp/yl-tvs-dolby-audio.log`.
- Current test inventory: iOS 446 / macOS 362 (inventory, not executed totals).
  Fixture copies and source parity checks passed.

At this earlier checkpoint, Profile 7 dual-layer playback remained unsupported.
The later experimental integration and its remaining limits are recorded below. Physical
surround-device routing and sustained playback are not established by these tests.

## Full FEL requirement and feasibility investigation

The user requires full FEL image information and retained HDR/Dolby Vision.
Discarding the enhancement layer, converting FEL to Profile 8.1, or falling back
to the HDR10 base layer does not satisfy this requirement. No such conversion
has been added. This initial investigation did not expand the production support matrix;
the subsequent experimental integration is recorded below.

The Baidu source is specifically FEL, not merely an unspecified Profile 7 file.
Its first decoded RPU reports `disable_residual_flag=0`, `vdr_bit_depth=12`, and
each component has `nlq_offset=512` and `linear_deadzone_slope=2048`. These do not
meet libdovi's zero-residual MEL criteria. The retained prefix contains 24 RPUs
and 103 type-63 enhancement-layer wrapper NALs. Those wrappers have layer ID 0;
filtering only nonzero layer IDs would not separate this source correctly.

An isolated macOS 27 probe unwrapped the enhancement payload into 1920x1080
Main10 HEVC. VideoToolbox decoded all 24 frames with zero errors and retained
`videotoolbox_vld` output. This establishes EL decoding on this Mac only, not
dual-layer synchronization, correct reconstructed color, sustained performance,
or iOS device support. Private test media remains outside the repository.
Evidence: `/private/tmp/yl-p7-fel-firstframe.json` and
`/private/tmp/yl-fel-upstream/el-vt.log`.

A follow-up probe decoded BL (3840x2160) and EL (1920x1080) in the same
process using VideoToolbox. Both streams produced 24 frames, with zero decode
errors and hardware-buffer output. Evidence:
`/private/tmp/yl-fel-upstream/dual-vt.log`. These frames have not been paired
and composited through the production renderer.

Current upstream mpv/libplacebo provides a useful implementation reference:
split BL/EL, decode independently, pair presentation timestamps, reshape BL,
and add inverse-quantized EL residuals before color conversion. It is not a
drop-in replacement for this player's single-decoder/sample-buffer path.
In particular, upstream pairing may emit BL alone when EL is missing, which
violates this user's requirement. Strict integration must instead surface a
failure if a required enhancement frame cannot be decoded or paired.

FEL pixel reconstruction must also be distinguished from complete Dolby display
mapping. The inspected libplacebo metadata path contains reshape, color matrices,
NLQ, and Level 1 scene brightness; that evidence alone does not establish Level
2/8 trim processing or native Dolby Vision output. Neither an ordinary HEVC
frame nor an HDR screenshot is sufficient acceptance evidence.

Acceptance work identified during the initial investigation:

- Implement and verify lossless BL/EL/RPU association across reorder, seek,
  switching, cancellation, and reconnect, with bounded frame ownership.
- Validate residual reconstruction and color transforms against known reference
  output, including scenes where FEL visibly changes the base layer.
- Establish the complete display-mapping path and its HDR output precision;
  metadata presence alone is insufficient.
- Qualify each supported profile, OS, and device independently. Apple documents
  the expansion of Profile 8.1 support to macOS/iOS in the 2026 system releases;
  that is not evidence of native Profile 7 support.

Primary references inspected on 2026-09-20:

- [libdovi MEL classification](https://github.com/quietvoid/dovi_tool/blob/main/dolby_vision/src/rpu/rpu_data_nlq.rs)
- [mpv FEL integration](https://github.com/mpv-player/mpv/pull/17932)
- [mpv frame pairing and BL-only fallback](https://github.com/mpv-player/mpv/blob/master/filters/f_enhancement_pair.c)
- [libplacebo FEL composition](https://github.com/haasn/libplacebo/blob/master/src/shaders/colorspace.c)
- [libplacebo FFmpeg metadata mapping](https://github.com/haasn/libplacebo/blob/master/src/include/libplacebo/utils/libav_internal.h)
- [Apple 2026 HLS HDR update](https://developer.apple.com/streaming/Whats-new-HLS.pdf)

## Experimental FEL integration (user request: “FEL 接入”)

Implemented the bounded single-track, length-prefixed HEVC Profile 7 path:

- Native BL/EL splitting, strict RPU parsing with the pinned FFmpeg parser,
  immutable metadata, copied stream configuration and independent epoch clones.
- Two VideoToolbox sessions under one playback lease, explicitly requesting
  10-bit output even when EL has no HDR transfer tag.
- Bounded timestamp pairing. Missing partners, duplicate pending timestamps,
  unknown timestamps, stale epochs and EOS mismatches cannot publish BL alone.
- Metal polynomial/MMR reshaping, signed NLQ residual composition and color
  conversion to linear BT.2020 RGBAHalf. Precise Metal math preserves rejection
  of invalid PQ-domain values and nonfinite/overflowed output.
- Integration with prepared open, seek recreation, reconnect, drain and disposal.
  Pixel buffers and retained source RPU have explicit memory receipts.

The rendering contract is intentionally narrow: unsupported signal encodings,
resampling modes, NLQ ranges and creative display metadata fail before playback.
The original RPU attached under `YlFELSourceRPU` is provenance only. It is not
presented as proof that Apple applies Dolby display transforms to reconstructed
RGB pixels. L1/L5/L6 metadata is retained by the parser; full dynamic Dolby display
management is not implemented. RGBAHalf is floating-point HDR output, not a claim
of lossless reproduction of every intermediate float32 value.

### Verification

- Native bridge: 24 actual access units parsed, plus malformed NAL/RPU, missing
  EL/RPU, metadata bounds, reset, clone and ownership cases. Existing audio 29/29
  and video metadata 35/35 checks passed against the final pinned libraries.
- All five native architectures independently rebuilt byte-for-byte; artifact
  contract and corruption-discrimination verifier checks passed.
- GPU tests match independent scalar calculations for signed/zero residual,
  polynomial/MMR mapping, half-resolution EL alignment, values above SDR white,
  and invalid numeric output rejection. The native sample layer accepts the
  floating-point buffer. This is not physical HDR visual acceptance.
- macOS focused XCTest: 28 passed, zero failures/skips. iOS 27 simulator:
  46 passed, zero failures/skips. Existing standalone HDR surface tests passed.
  After final memory/lifetime corrections, macOS FEL tests passed again (3/3).
  TVS signed macOS Debug build and bundle signature verification passed; the
  consumer source checkout remains unchanged. Current fixture inventory is
  iOS 449 / macOS 365 (inventory, not executed test totals).
- A private test-only derivative with display extensions removed and a unit NLQ
  maximum traversed the production parser, two hardware decoders and compositor:
  24 packets produced 24 RGBAHalf 3840x2160 frames, zero errors. It does **not**
  establish original-source fidelity; changing metadata is solely a test fixture
  construction step, never a production fallback.
- Removing the final enhancement-layer access unit from that test fixture
  produces 23 submitted packets and 23 composed frames, explicitly rejects the
  last access unit, and never emits its base layer alone. Final production probes
  were relinked and rerun after the last memory/lifetime corrections.
- The unmodified Baidu prefix through the production prepared-open path reports
  `decoder.dolby_vision_fel_metadata_unsupported`, with zero leaked native packets.

### Unresolved acceptance boundary

The requested complete FEL/Dolby playback is **not complete**. The actual source
has non-neutral Level 2 trims (including target PQ 2081, slope 2013, offset 2016,
power 1339), Level 4 metadata, and a normalized NLQ maximum of 0.125. The current
qualified compositor subset does not cover these. They are rejected rather than
silently ignored. Full display mapping needs a reliable implementation and
independent reference output; current open-source FEL reconstruction alone does
not establish that behavior. Physical iOS, long playback/seek stress and external
Dolby Vision output remain unverified.

Evidence logs are outside the repository under `/private/tmp/yl-fel-*`.
