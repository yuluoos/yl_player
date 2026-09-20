# FEL Integration Implementation Plan

**Goal:** Integrate Profile 7 full enhancement-layer reconstruction into the Apple managed player without discarding EL, RPU, or HDR precision.

**Architecture:** A pinned FFmpeg bridge separates compressed BL/EL and parses per-frame RPU. Two VideoToolbox sessions feed a bounded generation-aware pairing stage. A Metal compositor performs BL reshaping, EL inverse quantization and color conversion into high precision HDR buffers, using the existing clock and native display surface.

**Tech Stack:** FFmpeg 9.0.1, CoreMedia, VideoToolbox, Metal, CoreVideo, Swift.

**Spec:** `docs/verification/2026-09-20-dolby-audio-and-profiles.md`, Full FEL requirement. User explicitly requested implementation with “FEL 接入”.

## Constraints

- Preserve existing uncommitted Dolby audio fixes. Work on `codex/fel-integration`; do not commit or publish without a new user request.
- No BL-only fallback on missing, corrupt, unsupported, or mismatched EL/RPU.
- Keep all intermediary composition in floating point; no 8/10-bit quantization of reconstructed FEL output.
- Bound packet copies, metadata, pending frames and GPU output; retire all state on seek/switch/disposal.
- Preserve original RPU alongside parsed metadata. Distinguish reconstructed HDR from unverified full Dolby display trims/native external DV signaling.
- Production activation requires correct composition and an explicit supported display-mapping contract. Unsupported metadata must fail rather than be silently ignored.

## Task 1: Native FEL access units and metadata

Files: native `YlFFmpegBridge`, its public header, build recipe/contract and native FEL tests.

- [x] Write failing tests for valid P7 access units, truncated NAL lengths, missing EL/RPU, state reset, inherited RPU mappings, and caller ownership.
- [x] Add an opaque per-stream FEL context and immutable CoreFoundation access-unit output containing BL/EL bytes, format descriptions, parsed mapping/NLQ/color metadata and original RPU. Keep parsing inside the pinned bridge.
- [x] Validate profile, bit depths, polynomial/MMR bounds and metadata versions; fail unsupported mappings explicitly.
- [x] Rebuild all five architectures and independently verify artifact bytes and contract.

## Task 2: High precision FEL compositor

Files: new shared `YlFELMetadata.swift`, `YlFELCompositor.swift`, focused native tests.

- [x] Establish an immutable metadata schema with Task 1 before implementation.
- [x] Add failing numerical tests for signed residual, exact zero residual, polynomial/MMR reshaping, color transforms, malformed coefficients and unsupported display metadata.
- [x] Implement Metal composition with correct P010 unpacking, chroma siting and BL/EL sampling geometry. Compare against an independent CPU reference on synthetic nonzero-residual frames.
- [x] Validate HDR buffer output using the native sample-buffer surface; preserve source RPU separately from pixel transformations.

## Task 3: Playback integration

Files: shared video pipeline, prepared fallback, decoder policy and new FEL coordinator/pairing tests.

- [x] Write failing tests for reordered frames, generation isolation, missing partners, duplicate timestamps, bounded queues and EOS mismatch.
- [x] Select FEL only for a validated P7 stream; create two hardware decoder sessions and retain existing clock/output authority.
- [x] Submit BL/EL together, associate immutable metadata by presentation timestamp, and publish only composed pairs. Reserve memory before ownership transfers.
- [x] Integrate drain, cancellation, reconnect, seek and dispose; surface specific failure codes.

## Task 4: Consolidated validation and review

- [x] Run bridge, compositor and pairing tests; compile iOS and macOS product paths.
- [ ] Qualify actual-source FEL color against independent non-black reference output. The original source currently fails the explicit metadata capability gate; only a test-only supported-subset derivative traverses the complete pipeline.
- [x] Review integrated lifetime, memory, ordering and color correctness; fix material findings.
- [x] Record exactly which profiles, metadata levels and devices are qualified. Do not describe builds or dual decoding as completed FEL image validation.

## Execution ledger

- Initial state: previous audio changes already verified; no FEL production path exists.
- Ruling: execute the already-authorized integration directly; no repeat design approval or automatic commits.
- Ruling: parallel ownership is bridge, compositor, and root playback integration. The immutable access-unit/metadata interface is shared and must be confirmed before either producer or consumer changes it.

- Implemented: native BL/EL/RPU bridge; immutable metadata and Metal reconstruction;
  bounded pairing; two hardware decoder sessions; open/recreation/reconnect/drain/
  disposal integration. Existing audio changes remain intact and uncommitted.
- Reviewed and corrected: force ten-bit EL output, preserve keyframe status, charge
  retained RPU memory, compare pixel allocation against its own reservation, and
  avoid clearing decoder references concurrently with teardown. Metal fast math
  is disabled so invalid PQ-domain values cannot evade numeric rejection.
- Verified: native malformed/missing/reset/ownership cases, scalar/GPU comparisons,
  pairing cases, byte-identical five-architecture bridge rebuild, macOS 28 and
  iOS simulator 46 focused tests; final macOS FEL recheck 3/3. TVS signed Debug
  build and signature verification passed.
- Final production probes: supported-subset fixture 24 packets / 24 composed
  frames; fixture missing final EL 23 / 23 with explicit rejection of the last
  access unit; original Baidu prefix rejected with the metadata-specific code.
- Still incomplete: complete Dolby creative display mapping, the actual source's
  NLQ range, independent full-color reference qualification, physical iOS and
  sustained seek/switch stress. This is experimental integration, not fulfillment
  of the user's complete-FEL/Dolby playback requirement.
