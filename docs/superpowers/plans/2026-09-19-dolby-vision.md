# Dolby Vision HDR Implementation Plan

> **For agentic workers:** Use the bounded ownership tasks below; preserve existing uncommitted startup and stall diagnostics changes.

**Goal:** Correct Profile 5 color while retaining high bit depth and Dolby metadata on iOS; use a native Mac probe to validate the shared display path.

**Architecture:** Preserve demux metadata through context-aware format reconstruction, decode into 10-bit pixel buffers, and display those buffers unchanged in an iOS AVSampleBufferDisplayLayer. Flutter negotiates a native video view while retaining control layout and old-backend Texture compatibility.

**Tech Stack:** FFmpeg bridge, CoreMedia, VideoToolbox, AVFoundation, Flutter/Pigeon.

**Spec:** docs/verification/2026-09-19-ios-hdr-dolby-vision.html. User authorized implementation with “修复”.

## Constraints

- No SDR tone mapping as the success criterion; no user media or credentials checked in.
- Existing 8-bit SDR path remains valid; preserve seek, switch and lifecycle authority.
- Metadata repair must apply to both initial configuration and in-band HEVC reconstruction.
- Mac native probe is validation, not a claim of macOS Flutter HDR support.
- Device visual validation remains separate from automated/build success.

## Tasks

- [x] Native Mac spike: dvh1 + real dvcC + rebuilt hvcC produces x420 and 293-byte RPU; image-backed sample accepted by display layer without error. Color/EDR acceptance pending colored sample.
- [x] Bridge: context-aware format factory with metadata validation, regression harness, independently reproduced XCFramework and lock. Owner dv_bridge.
- [x] Flutter: optional native surface provider, nullable negotiated nativeViewType, controller forwarding, UiKitView preserving geometry/placeholder; generated channels and focused tests. Owner native_view_dart.
- [x] Native output: shared high-bit-depth policy and sample construction; iOS view factory keyed by existing texture identity, bounded frame retention, detach/reattach/clear/dispose; layer failures routed to current authority. Owner root.
- [x] Decode integration: dvh1 hardware support and 10-bit attributes; context-aware in-band reconstruction; reject unsupported output rather than render green. Owner root.
- [x] AVPlayer path: negotiate high-bit-depth output for HDR assets on native surface while retaining SDR attributes. Owner root.
- [ ] Verify: policy/sample unit tests, bridge regressions, Flutter tests/analyze, native simulator compile, Mac native decode/display, current source visual comparison when available. Review integrated diff once.

Completed verification: Dart245, bridge35+sanitizers+independent artifact rebuild, nativeMacXCTest10, standalonepolicy/mailbox/sample/lease, TVSiOSbuild. iOSnativeviewtestcompiled butruntimecancelled because simulatorShutdown. Reviewfourfindingsfixedandcleared. Visualcoloredscene, activeHDRhighlights andphysicaliOSacceptance remain pending.

macOS follow-up: user runtimeerror exposed missing product surface; added NSView factory, Macoutput andAppKitViewnegotiation, removedglobalMacVT HDRrejection while preserving negotiatedsurface guard. 65targetedDart and12Macnative tests passed; signed TVSMacbuildpassed. Source10.28s coloredframe matched AVPlayer reference after preservingdvcC; actualHDRheadroom,endurance,iOSdevice stillpending.
