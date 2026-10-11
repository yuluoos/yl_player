# External text subtitle runtime

This slice connects the existing catalog/session API and bounded SRT/WebVTT
parser to actual file/HTTP reads and Flutter rendering. Enable explicitly with
`YlPlayerController.create(enableTextSubtitles: true)`. The default retains the
optional native SPI behavior. Enabling alongside a native subtitle SPI is
rejected, avoiding two owners of the catalog. This is external text only;
embedded tracks, TTML, ASS/SSA, bitmap subtitles, HDR brightness qualification
and protected-video composition remain separate P02 work. Protected surfaces
reject subtitle commands and never receive this Flutter overlay.

The controller merges local subtitle publications with native state using a
separate native revision watermark and monotonically increasing public revision.
With this opt-in, event revisions refer to the public snapshot observable at
controller delivery; original session identity and occurredAt remain unchanged.
They are observation revisions, not the originating native revision. This keeps
late FirstFrame milestones observable without an unbounded historical mapping.
The default native-SPI path retains its existing event revisions.
Native snapshots cannot erase the local catalog. Each catalog replacement reads
and validates all documents before atomically committing. A newer replacement
cancels the prior read; failure keeps the committed catalog and selection.
Selection and offset commands during a read apply immediately to the committed
catalog; completion preserves the latest selection if its ID still exists.
New sessions reset catalog, selection and offset; stop/dispose cancel reads.

Cues use the published media position, with no wall-clock extrapolation. Thus
pause and buffering freeze subtitles and speed follows the native media clock.
Seek clears the overlay immediately and waits for a position snapshot after its
ACK. The display precision is bounded by the configured native position update
interval, not a frame-accurate synchronization claim. Before FirstFrame, after
completion/failure/stop, or without video geometry, no overlay is drawn.

The runtime supports plain text and balanced b/i/u tags, common named entities
and numeric Unicode entities. Other markup is rejected explicitly. WebVTT
position/align are supported for horizontal, bottom-stacked cues. Text is kept
upright within the visible video rectangle after fit, crop, alignment, pixel
aspect ratio and rotation. It ignores pointer input and uses a fixed white text
style with a dark background. No CSS, fonts, external references or HTML run.

Files and HTTP(S) have a 4 MiB aggregate input and 10,000 aggregate cue budget;
old and replacement catalogs may coexist during atomic replacement (up to twice
the catalog budget). At most one replacement read is active. Parsing/render span
counts are bounded separately. HTTP platformDefault uses a 30-second total
deadline, at most five redirects, no retries, system certificate validation,
identity encoding and permanently strips credentials on origin change. Managed
HTTP is implemented by the [managed network extension](2026-10-11-subtitle-managed-network.md),
with per-hop/read deadlines and explicit retry/redirect budgets. File reads
are streamed and cancellable. Errors are sanitized command failures; they do not
commit a damaged catalog or decide PD-03's eventual playback-failure policy.

Validation uses owned local files, loopback HTTP and Flutter widget rendering.
It does not claim native-device playback, HDR or DRM visual acceptance.

## TTML extension (2026-10-11)

The subsequent [TTML text subset](2026-10-11-subtitle-ttml.md) adds explicitly
selected `YlSubtitleFormat.ttml` to the same resource/catalog/clock pipeline.
The earlier SRT/WebVTT markup and layout rules remain format-specific; TTML
uses already decoded styled runs and clipped percentage regions. Advanced
TTML and full native/device format acceptance remain outside this extension.
