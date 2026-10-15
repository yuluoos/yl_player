# P02 remaining engineering and controlled acceptance

> Execute inline with superpowers:executing-plans. The user authorized completion,
> verification and local commits; on 2026-10-14 confirmed no authorized DRM media,
> license configuration or physical device is available. Do not wait for those.

**Baseline:** c3b8b902341638ffd8c96c3c2744c52d1c60471b, codex/fel-integration.
**Spec:** ../specs/2026-09-20-playback-expansion-requirements.md;
../specs/2026-09-26-subtitle-contract.md; ADR 0008. This continuation supersedes
stale unchecked implementation status in the original P02 plan, not its acceptance
requirements. Existing parsers, managed loaders, embedded discovery and stable
multi-audio identities remain the base. No long-play, weak-network ABR or P05 work.

## Global constraints

Retain Android 24 / iOS 15 / macOS 12. Preserve shared checkout changes. Commit
explicit files only, no push. Run native platforms sequentially. No protected
pixel reads, texture conversion or security downgrade. Subtitle resources remain
clear, bounded and managed; protected embedded media is never demuxed by Dart.
Independent subtitle failures keep video alive under approved PD-03. Unsupported
syntax fails explicitly; no claim of full libass or full TTML implementation.
Physical DRM, HDCP, HDR luminance and external display acceptance stay open with
specific missing inputs. Controlled proofs must not be relabeled device proofs.

## Review Focus

- Pending bitmap completion after seek, off, same-ID replacement or new session.
- Protected descriptor capability, identity, first-frame and geometry gates;
  old adapters must fail closed and encrypted discovery must not perform I/O.
- ASS smart line wrapping with styles, explicit breaks, unbreakable/CJK text,
  and bounded work for the maximum admitted cue size.
- Seven-format actual renderer effects, media-clock offset/pause/seek, multiple
  players and native surface lifecycle; distinguish simulation from real output.
- Error redaction, HDR route preservation, API comments and honest evidence matrix.

### Task 1: Isolate asynchronous subtitle image failures

Files: player_controller.dart, text_subtitle_runtime.dart, text_subtitle_overlay.dart,
pgs_overlay.dart, subtitle_resource.dart, platform-interface failure.dart and tests.
Interface: current-render callback captures runtime presentation generation and cue;
reports subtitle.resource_unavailable (resource, command, nonretryable), suppresses
stale failures and failed active cues. Keep decoder exception text private.
1. Add failing widget/session tests for partial decode release, one event, video
   continuity, stale completion after seek/off/reselection/replacement/disposal.
2. Add bounded active failure tracking and internal callback propagation, with
   API comments. Preserve global two-job image queue and disposal.
3. Run focused tests then full yl_player suite. Expected: green, no engine errors.
4. Commit source, tests and evidence for this independently reviewable slice.

### Task 2: External subtitles on negotiated protected native surfaces

Files: native_video_surface.dart, both adapter DRM codecs, controller/session/view,
protected runtime/view/adapter tests and controlled probe integration.
Interface: supportsSubtitleOverlay defaults false on descriptor; only known bundled
surface implementations opt in. External resources retain their own managed policy.
Discovery of protected embedded subtitles rejects before I/O. Composition is a
Flutter sibling overlay above the native surface, contain/center only; authoritative
geometry and current first-frame required. No protected surface capture.
1. RED: old descriptor denial, opt-in external selection, encrypted discovery
   denial, stale identity/no-geometry/no-first-frame hiding, no texture/opacity.
2. Implement gates and sibling composition. Document capability responsibilities.
3. Run Dart tests and clear native-view probes sequentially on all three hosts;
   test resize, multiple players, detach/reattach, generation/session replacement.
   Expected: controlled tests green; no claim of actual DRM decryption.
4. Commit scoped changes and actual evidence.

### Task 3: Bounded ASS default smart wrapping

Files: ass_parser.dart, ass_overlay.dart, new internal wrapping helper if needed,
ASS parser/render tests and owned fixtures. Retain existing fonts/outlines/motion.
Interface: WrapStyle and q accept 0..3; 0 balances lines preferring longer upper,
3 longer lower; 1 greedy and 2 no soft wrapping. Preserve styled runs and hard breaks.
1. RED: ordinary omitted WrapStyle, explicit 0/3 and q overrides, soft/hard breaks,
   balanced measured bounds with different upper/lower preference.
2. Implement bounded layout and resource release, including fallback/budget cases.
3. Run parser/effects tests plus full package suite. Expected: green; unsupported
   advanced vector/karaoke/transform syntax remains explicit in matrix.
4. Commit implementation, API comments, references and evidence.

### Task 4: Controlled integration and closure report

Files: example/integration_test/subtitle_playback_test.dart, owned test resources,
tool subtitle evidence helpers as needed; original P02 report, platform-support,
overview and final evidence manifest.
1. Add real-player seven-format selected/off/offset/seek/pause effects and media
   clock observations; record fixture hashes and device/runtime identities.
2. Run macOS, iOS Simulator, Android emulator separately. Reuse valid existing
   audio/DASH/native evidence without claiming physical sound or DRM/HDR hardware.
3. Audit public API comments, run all affected Dart packages/analyzer/generation
   checks; native/consumer checks only where changes require them. Record failures
   and skips individually, no skip-as-pass.
4. Reconcile every P02 requirement with current code/test/evidence or concrete
   unavailable external input; leave unsupported effects explicit, not implied.
5. One fresh final review across this continuation; fix important findings with
   RED→GREEN and affected suite, archive ledger, then local scoped final commit.
