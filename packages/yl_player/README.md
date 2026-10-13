# yl_player v0.2 development API

`yl_player` is the application package. It requires Dart 3.12 and Flutter 3.44
and endorses Android, iOS, and macOS implementations. Version 0.2 is a breaking
cutover; there is no v0.1 compatibility shim.

## Lifecycle

Create one player during asynchronous startup or `initState`, never from
`build`. A Load returns a handle for one committed session. Ready and First
Frame are later, independent milestones. The following example is exercised by
`test/documentation_examples_test.dart`:

```dart
import 'package:yl_player/yl_player.dart';

Future<void> playVideo(Uri uri, {bool expectVideo = true}) async {
  final player = await YlPlayerController.create(
    options: const YlPlayerOptions(
      decoderPolicy: YlDecoderPolicy.hardwarePreferred,
      audioPolicy: YlAudioPolicy.appManaged,
    ),
  );
  try {
    final source = YlNetworkSource(
      uri,
      intent: YlStreamIntent.onDemand,
      format: YlMediaFormat.mp4,
      request: YlHttpRequest(
        headers: const {'User-Agent': 'yl-player-demo'},
      ),
    );
    final assessment = await player.assess(source);
    if (assessment.outcome == YlSourceAssessmentOutcome.incompatible) {
      throw YlPlayerException(assessment.rejection!);
    }

    final session = await player.load(
      source,
      options: const YlLoadOptions(
        bufferStrategy: YlBufferStrategy.automatic(),
      ),
    );
    await session.ready;
    await session.play();
    if (expectVideo) await session.firstFrame;
    await session.seekTo(const Duration(seconds: 10));

    final replacement = await player.load(source);
    try {
      await session.pause();
      throw StateError('The replaced session unexpectedly remained current.');
    } on YlPlayerException catch (error) {
      if (error.failure.code != YlFailureCodes.sessionStale) rethrow;
    }
    await replacement.play();
    await player.stop();
  } finally {
    await player.dispose();
  }
}
```

`assess` is decoder-free where possible. `compatible` means the known route and
requested policies can be enforced; it does not prove reachability, media
integrity, codec initialization, or runtime timing. `requiresInspection` means
Load must inspect the source before it can decide. Load can therefore still
fail after either non-incompatible result.

Load completes only after the candidate commits and its matching authoritative
state has been accepted. `session.ready` means decoder/media readiness.
`session.firstFrame` means a frame from that session reached the committed
public output. Do not await First Frame for audio-only media. A newer Load,
successful Stop, or Dispose makes the old handle fail locally with
`session.stale`; a rejected replacement or rejected Stop leaves the accepted
session usable.

Session commands are `play`, `pause`, `seekTo`, `seekToLiveEdge`,
`setPlaybackSpeed`, `selectAudioTrack`, and `setVideoConstraints`. Player-wide
commands are `setVolume`, `stop`, and `dispose`. Await or otherwise observe every
returned Future. Stop keeps the player and texture reusable; Dispose is
idempotent and terminal.

## Rendering and observation

```dart
YlPlayerView(
  controller: player,
  placeholder: const Center(child: CircularProgressIndicator()),
)
```

`YlPlayerView` contains no controls or application state. It defaults to a
centered `BoxFit.contain` texture on black and keeps the placeholder visible
until the current session's First Frame. Subscribe to `player.states`,
`player.events`, or the controller's `Listenable` notifications. State and
events are authoritative native observations; command rejection does not
invent either.

## Sources and policies

Use `YlFileSource`, `YlNetworkSource`, or Android-only
`YlAndroidContentSource`. `YlHttpRequest.headers` is ordinary metadata.
Authorization, cookies, API keys, tokens, and every other credential-bearing
value belongs in `credentials` so the origin policy can strip it permanently
after a cross-origin transition.

Player-wide decoder and audio ownership choices live in `YlPlayerOptions`.
Autoplay, start position, buffer strategy, video constraints, and an optional
decoder override live in `YlLoadOptions`. See the repository
[policy semantics](../../docs/policies.md), [support matrix](../../docs/platform-support.md),
and [diagnostics guide](../../docs/diagnostics.md).

## Errors

Public asynchronous failures are `YlPlayerException` values carrying a
`YlFailure`. Branch on stable category, code, retryability, and scope. Log the
opaque diagnostic ID for correlation. Do not log source locators or request
metadata. See [diagnostics](../../docs/diagnostics.md).

## External subtitles (opt-in)

Create the controller with `enableTextSubtitles: true` to use the Dart-owned
external SRT/WebVTT/TTML/ASS/SSA text and PGS/VobSub bitmap runtime on Android, iOS or macOS. `YlPlayerView` then draws
selected subtitles over ordinary video without an extra widget:

```dart
final player = await YlPlayerController.create(enableTextSubtitles: true);
final session = await player.load(const YlFileSource('/absolute/video.mp4'));
await session.replaceExternalSubtitles([
  const YlExternalSubtitle(
    id: 'english',
    source: YlFileSource('/absolute/english.srt'),
    format: YlSubtitleFormat.srt,
    language: 'en',
  ),
]);
await session.selectSubtitleTrack('english');
await session.setSubtitleOffset(const Duration(milliseconds: 500)); // Delay.
// Build YlPlayerView(controller: player) in the widget tree.
await session.selectSubtitleTrack(null); // Immediately hide subtitles.
// Dispose the controller when its owning widget is removed.
```

Use `YlNetworkSource` for HTTP(S), including separately scoped credentials.
Both network policies are supported. `platformDefault` uses a 30-second total
read deadline, five redirects and no automatic retries. For
`networkPolicy: const YlNetworkPolicy.managed()`, the defaults are 10 seconds
through response headers, 15 seconds of body inactivity, three retries,
500 ms exponential backoff capped at 8 seconds, and five redirects across all
attempts. Nonempty body chunks reset only the read deadline; managed requests
have no total-call timeout. Valid `Retry-After` seconds or HTTP dates override
backoff within its cap; excessive values stop retries. TLS/certificate errors,
permanent HTTP errors, unsupported encodings, oversized input and parse errors
are never retried. Cancelling a session or replacement also cancels backoff.
Cross-origin redirects permanently strip credentials, including retries and a
later return to the original origin. File/HTTP input is streamed within a
4 MiB aggregate catalog budget, with at most 10,000 cues and bounded text spans.

Replacing the catalog is atomic; a failed download or parse leaves the previous
catalog usable and reports a sanitized `YlPlayerException`. A newer replacement,
load, stop or dispose cancels pending I/O. New sessions reset subtitles and offset.
In this opt-in mode, event `revision` identifies the public snapshot at delivery;
`occurredAt` retains the original event time. This avoids mixing native revisions
with locally published subtitle state.
Selection starts off; `[]` removes all external entries. Same-ID replacement
updates content while preserving current selection. Positive offsets delay cues.

SRT/WebVTT rendering supports plain UTF-8 text, balanced `b`/`i`/`u` markup, common entities,
and horizontal WebVTT position/align settings. Unsupported markup is rejected.
Cue timing follows published media positions, so precision depends on
`YlPlayerOptions.positionUpdateInterval`; no independent timer advances captions
while paused or buffering. Seek hides text until a post-ACK position snapshot.
Text stays upright in the visible video aperture after fit, crop, PAR and rotation.

For TTML, set `format: YlSubtitleFormat.ttml` with a file or network source.
The supported TTML1 subset uses the `http://www.w3.org/ns/ttml` namespace,
media clock or h/m/s/ms timing, parallel body/div containers and finite paragraph
intervals. It renders nested untimed spans, line breaks, inherited/referenced
bold/italic/underline/color/text alignment, and percentage regions with
before/center/after vertical alignment. XML whitespace and entities are decoded
once; text resembling HTML is displayed literally. Regions are clipped to the
visible video aperture. DTD, external references, timed spans, sequential/frame
or tick timing, custom fonts/sizing, animation, vertical text and unsupported
properties are rejected explicitly. See the [TTML subset contract](../../docs/superpowers/specs/2026-10-11-subtitle-ttml.md)
for precise limits; this is not a full TTML/IMSC conformance claim.

For ASS/SSA, set `format: YlSubtitleFormat.ass` or `.ssa`. The UTF-8 text
subset requires explicit PlayResX/Y and WrapStyle 1 or 2. It renders font
fallback, basic styles/colors, outline/shadow, margins/alignment, positioned
text, layers, movement and fade driven by media time. Smart wrapping 0/3,
font attachments, vector drawing/clips, karaoke, transformations and unsupported
style fields fail explicitly. This Flutter renderer does not promise libass
font-metric or pixel equivalence. See the [ASS/SSA subset contract](../../docs/superpowers/specs/2026-10-11-subtitle-ass.md)
for accepted tags and budgets.

For PGS, set `format: YlSubtitleFormat.pgs` with a local `.sup` file or HTTP(S)
source. The bounded binary SUP subset renders palettes, partial palette updates,
fragmented RLE objects, cropping, windows, overlap and clear events. Selection,
offset and seeking use media time; ordinary-video fit and source cropping apply.
Expanded bitmap data is capped at 64 MiB per catalog; only active frames create
engine images, with late asynchronous results disposed after a switch or reset.
Unsupported segment/plane semantics fail explicitly. See the [PGS subset contract](../../docs/superpowers/specs/2026-10-11-subtitle-pgs.md).

For VobSub, set `format: YlSubtitleFormat.vobsub`, `source` to the `.sub`
binary and `companionSource` to its `.idx` index. Each resource uses its own file
or managed HTTP policy. A unique matching `language` selects a substream;
otherwise the index default (or first stream) is used. The DVD subset renders
field RLE, RGB palettes, contrast, positioning and timed control updates, sharing
the 64 MiB bitmap catalog budget with PGS. Unsupported effects fail explicitly.
See the [VobSub subset contract](../../docs/superpowers/specs/2026-10-11-subtitle-vobsub.md).

This opt-in owns the subtitle catalog and cannot be combined with a native
subtitle SPI. Embedded support covers the Matroska and MP4 text routes below.
It does not support WebVTT CSS/regions/karaoke or protected video overlays. HDR subtitle brightness
and native-device synchronization remain unqualified. Without the opt-in, the
existing native capability/SPI gates continue to apply.

### Matroska, WebM and MP4 embedded subtitles

With the same `enableTextSubtitles: true` controller, discover supported text and bitmap tracks from
its committed file or HTTP(S) Matroska/WebM/MP4 source, then select a returned identity:

```dart
final session = await player.load(YlFileSource('/media/movie.mkv'));
await session.discoverEmbeddedSubtitles();
final tracks = player.state.subtitles.tracks.where((t) => !t.isExternal);
if (tracks.isNotEmpty) await session.selectSubtitleTrack(tracks.first.id);
```

`YlPlayerView` renders Matroska UTF8/SRT, ASS/SSA, WebVTT, PGS and VobSub, and non-fragmented MP4
`tx3g` (mov_text), `wvtt` (WebVTT) and `stpp` (TTML) tracks using media time.
Fragmented MP4 also supports `tx3g`/`wvtt`/`stpp` when initialization and fragments
are in the same complete file or stable HTTP resource.
Discovery is explicit and bounded; Matroska TrackUID (`mkv:<UID>`) or MP4 Track ID
(`mp4:<ID>`) identifies a track within the session. Replacing/clearing external subtitles preserves embedded entries;
rediscovery preserves external entries and a still-present selection. A new
session starts with subtitles off. Unsupported codecs/effects fail atomically.

For a network MKV or MP4, load a `YlNetworkSource` with its request metadata and network
policy, then call the same discovery method. HTTP(S) servers must return single
206 byte ranges with a stable strong ETag and total length. Managed connect/read
deadlines, retry/redirect budgets and credential origin restrictions apply to the
whole discovery. Later ranges use If-Match; changed versions fail atomically.
The scan uses a bounded cache and request/byte budgets, with no full-body fallback.

Separate initialization/media segment URLs, HLS/DASH and native subtitle callbacks remain
unsupported. No additional native subtitle capability or physical-device
acceptance is claimed. See the [embedded subset contract](../../docs/superpowers/specs/2026-10-11-subtitle-embedded.md)
the [network range contract](../../docs/superpowers/specs/2026-10-11-subtitle-network-matroska.md)
and [MP4 contract](../../docs/superpowers/specs/2026-10-11-subtitle-mp4.md).

MP4 tx3g text is decoded literally (UTF8 or BOM UTF16), including basic styles,
font fallback, size, color and horizontal alignment. `format: srt` on its catalog
entry denotes normalized standard text, not the encoded sample format. Complex
edits, positioning, karaoke and per-sample forced effects are rejected. Font
metrics, track geometry and device synchronization are not QuickTime-certified.

MP4 `wvtt` entries retain `format: webvtt`. Sample-local `vttc` payloads support
basic b/i/u markup, entities and horizontal align/position settings; `vtte`
clears cues. Multiple cues in one sample share its media interval, including
edit-list timing. Unsupported CSS/regions/advanced settings and malformed boxes
fail atomically. See the [MP4 WebVTT contract](../../docs/superpowers/specs/2026-10-11-subtitle-mp4-webvtt.md)
for the bounded subset and validation limits.

MP4 `stpp` entries use `format: ttml` and the existing bounded TTML styled-text
and percentage-region renderer. XML times are track composition times, clipped
to each sample and mapped through supported edits. Documents keep their own
style/region scope, and their raw bytes count toward the shared catalog budget.
Auxiliary images, cell/pixel font styling and advanced TTML/IMSC remain unsupported;
see the [MP4 TTML contract](../../docs/superpowers/specs/2026-10-11-subtitle-mp4-ttml.md).

For fMP4, `trex`/`tfhd`/`tfdt`/`trun` supply bounded sample locations and timing.
The same track selection, tx3g/WebVTT/TTML rendering and managed range rules apply.
This is explicit discovery of a complete resource, not live segment polling.
See the [fMP4 contract](../../docs/superpowers/specs/2026-10-11-subtitle-fmp4.md)
for defaults, addressing, edits and unsupported layouts.

Fragmented `tx3g` uses the same literal styled text and normalized `srt` catalog
format as non-fragmented MP4; sample-description changes update default styles.
See the [fMP4 tx3g contract](../../docs/superpowers/specs/2026-10-11-subtitle-fmp4-tx3g.md).

MP4 tracks can also combine initial sample-table subtitles and later fragments.
Discovery joins them by Track ID, checks decode continuity and subtitle byte
extents across both portions, and publishes the catalog atomically.
See the [hybrid MP4 contract](../../docs/superpowers/specs/2026-10-12-subtitle-hybrid-mp4.md).

Matroska WebVTT supports `S_TEXT/WEBVTT` and the FFmpeg-compatible
`D_WEBVTT/SUBTITLES` / `D_WEBVTT/CAPTIONS` mappings through the same file/managed
HTTP discovery API. Cue text, identifier and horizontal position/alignment are
rendered using the existing strict WebVTT subset. Global headers and NOTE blocks
are validated and budgeted. Advanced CSS/regions/inline timestamps remain
unsupported; see the [bounded contract](../../docs/superpowers/specs/2026-10-12-subtitle-matroska-webvtt.md).

WebM embedded WebVTT (`D_WEBVTT/SUBTITLES` / `CAPTIONS`) is available through
`discoverEmbeddedSubtitles()` for files and managed HTTP(S). Use `automatic` for
content detection or `YlMediaFormat.webm` to require a WebM DocType; explicit
Matroska and WebM hints reject mismatched content. Track identities retain the
`mkv:<UID>` EBML namespace. The existing bounded WebVTT renderer and managed
Range rules apply; this does not expand native video decoding support. See the
[WebM contract](../../docs/superpowers/specs/2026-10-12-subtitle-webm.md).

Matroska `S_HDMV/PGS` bitmap tracks also use `discoverEmbeddedSubtitles()` and
`mkv:<TrackUID>` selection. Raw binary segments use container presentation times
and optional duration caps; palette updates and clear displays reuse the PGS
overlay. Embedded and external tracks share the 4MiB encoded / 64MiB RGBA catalog
budgets. See the [PGS container contract](../../docs/superpowers/specs/2026-10-12-subtitle-embedded-pgs.md).


Matroska `S_VOBSUB` bitmap tracks use the same discovery/selection API. The
container carries global IDX size/palette settings and raw DVD SPU blocks, so no
external IDX/SUB pair is needed. Container time and duration caps constrain SPU
start/stop and alpha updates. Existing two-field RLE rendering, managed ranges,
atomic catalogs and shared encoded/RGBA budgets apply. See the
[VobSub container contract](../../docs/superpowers/specs/2026-10-12-subtitle-embedded-vobsub.md).


Matroska subtitle tracks may carry up to four ordered `ContentEncoding` stages for blocks,
CodecPrivate, or both: zlib or header stripping. Restoration precedes the existing text/bitmap decoder, with
strict zlib framing/checksum validation and bounded output. Stored compressed
bytes/settings, every intermediate output and final content count toward the shared input budget,
including later external subtitle replacements. Encryption,
next-encoding scope and WebM compression remain unsupported. See the
[compression-chain contract](../../docs/superpowers/specs/2026-10-13-subtitle-compression-chain.md).


Compressed CodecPrivate is restored before UTF-8 and codec-specific header
validation. Private-only scope leaves blocks unchanged; combined scope restores
the header and each block independently. Both stored and restored header bytes
remain charged, including empty tracks and subsequent external replacements.
See the [private-header contract](../../docs/superpowers/specs/2026-10-12-subtitle-private-compression.md).

MP4 subtitle discovery shares its 200,000 structural-box allowance across the
container index, tx3g configuration/sample-modifier boxes, WebVTT
configuration/sample/cue boxes and TTML configuration boxes. Tracks, sample-description changes, initial samples and later fragments
use the same allowance. Exceeding it reports `subtitleTooLarge` atomically,
retaining the previous subtitle catalog and selection. Existing local child,
payload and cue limits also apply; this is not a whole-process memory bound.

### MP4 extended subtitle language

Embedded tx3g/wvtt/stpp tracks in ordinary, fragmented and hybrid MP4 now read
`elng` as a well-formed BCP 47 tag, preserving its spelling and overriding the
packed `mdhd` language. Missing `elng` retains the packed language. Track identity
and selection remain based on track ID. Tags are limited to 128 ASCII characters;
malformed metadata rejects discovery atomically. Existing `mdhd` validation still
applies. This performs syntax checking, without registry validation, canonicalization
or automatic language selection. File and managed HTTP use the existing bounded
loader. See the [contract](../../docs/superpowers/specs/2026-10-13-subtitle-extended-language.md).

## Audio track identity and Apple DASH

Select audio using an ID from the current session's `audioTracks` catalog and
`selectAudioTrack(id)`. Treat IDs as opaque: labels and languages may repeat,
including main and commentary tracks in the same language. Command completion
acknowledges selection; it does not prove physical audible output.

The Apple static clear DASH subset supports up to 16 AAC-LC audio AdaptationSets
with one Representation each. Every Period must keep the same complete semantic
identity set; ordering may change. Same-session quality replacement retains the
chosen track. Ordinary AVPlayer restoration uses system option identities and
reports `track.not_found` if the chosen option disappears. New loads reset the
choice. This does not add audio ABR, mixing or strict managed DASH admission.

Android exposes one logical audio choice per Media3 group. DASH choices use
declared AdaptationSet identity and semantic metadata, so Representation rename,
bitrate changes and group reordering do not redirect a selection. Other formats
require stable available Format IDs and metadata; missing IDs are not replaced
by array positions, and ambiguous content is rejected. Explicit selection
survives same-session restoration and is applied to reading-ahead Periods. If the
chosen content disappears, `track.not_found` can arrive before the Period boundary
during prebuffering. Transient empty catalogs preserve intent; new loads reset it.
