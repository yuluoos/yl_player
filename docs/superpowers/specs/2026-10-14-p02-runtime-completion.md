# P02 runtime continuation contract

Continues the approved P02 subtitle contract, PD-03 (ADR 0008), and P06 native
view architecture. No DRM credentials or physical acceptance devices were
available on 2026-10-14; user requested engineering and controlled validation.

## Image resource failure ownership

`subtitle.resource_unavailable` is a resource-category, command-scope,
nonretryable failure. The event contains a stable sanitized message and diagnostic
identity, never decoder text, paths, subtitle payloads or headers. It does not
change video status or disable the selected subtitle track. Only the failed active
cue is hidden; later cues still render. The runtime holds at most the current
active set of failed cues. Seek, off, reselection, offset, catalog/session changes
invalidate callbacks and clear this set. Native position revisions alone do not
invalidate current work. Widget jobs still limit global image creation to two and
release partial/late images. PGS and VobSub share this path.

## Protected external subtitle overlay

`YlProtectedVideoSurface.supportsSubtitleOverlay` defaults false. The bundled
AVPlayerLayer and explicit hybrid Android secure SurfaceView adapters opt in; old
or unknown adapters remain closed. The descriptor identity, platform, current
session first-frame milestone and authoritative video geometry gate rendering.
The first-frame milestone is session-scoped: on native view remount, current
clear subtitles may appear on the native black cover until video readiness.
The native cover still independently authorizes protected video.
Protected view layout remains contain/center. A separate Flutter sibling paints
clear subtitle resources; video is never read back, flattened into a Flutter
texture, transformed through opacity, or decrypted by the subtitle runtime.

Protected embedded discovery rejects before I/O even with overlay support.
External subtitle resources retain their own managed policy and bounded catalog;
video DRM configuration grants no license or access to those resources. A missing
or stale protected surface denies loading/selection. Resources do not need current
video geometry to load, but cannot render until geometry and first frame exist.

Controlled probe captures only the clear subtitle repaint boundary. It observes
native clear playback readiness/clock and independent subtitle paint, dimensions,
resize, two owners, off/on, replacement and release. It is not proof of actual DRM
license exchange, secure decoding, visible composition on physical devices,
screenshot protection, HDCP, external display routing or HDR luminance.

## ASS smart wrapping

WrapStyle/q 0 and 3, including omitted WrapStyle (default 0), are admitted. The
renderer keeps engine Unicode line breaks and styled text, narrows the width to
balance without increasing line count, and for mode 3 moves legal break units to
prefer a wider lower line. Hard breaks cannot move. NBSP and joined graphemes use
engine line boundaries rather than word-selection boundaries. Mode 1 remains
greedy; mode 2 disables soft wrapping and honors both soft and hard ASS escapes.

Work is bounded by ten whole-cue width probes and at most 128 local shaping
operations. When this optimization budget is exhausted, valid existing line
breaks remain; this is approximate smart balancing, not libass pixel equivalence.
Budget is reserved before each local probe, including failed indivisible-line probes.
All temporary TextPainters are disposed. Prepared styled runs are retained only
for active cues (at most 64); motion/fade frames reuse them. System font-change
notifications invalidate cached breaks and repaint even while paused; unmount
removes that listener. Text remains subject
to the existing 16,384-code-unit, 512-style-run, aggregate input and font-identity
budgets. Inserted breaks add at most one code unit per original code unit; the
prepared text is bounded to twice admitted active text, with no native font cache
or downloadable font resources introduced.

The existing supported ASS/SSA subset is unchanged otherwise: fonts with system
fallback, colors, outlines, shadows, alignment/position, movement/fade and layers.
Vector drawing, karaoke, arbitrary transforms, clips, external font attachments
and unsupported effects still reject explicitly. TTML remains its documented
bounded subset. Supporting these containers does not claim every legal effect.

Semantic reference: [Aegisub ASS override tags, Wrap style](https://aegisub.org/docs/latest/ass_tags/#wrap-style).
No third-party renderer source or binary was incorporated.
