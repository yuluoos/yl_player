# P02 physical-device continuation — 2026-10-20

Baseline `68aa8c14`, branch `codex/p02-tracks-subtitles`. The complete current
requirement matrix remains in the [P02 report](../../2026-09-26-remaining-02-tracks-subtitles.md).
This continuation closes same-player remount evidence and adds physical iPhone
screenshots. **Full P02 physical acceptance remains open.**

## Change and observation

A real iPhone sequence found that after playing to EOF, pausing and seeking back
into the video, AVPlayer remained paused without a time-control notification.
The public status stayed `completed`, so current subtitles remained hidden.
The native fix publishes `paused` only after a successful current user seek with
paused intent and an actual position before EOF. It does not start playback.
The regression preserves `completed` at EOF, restores the rendered cue at 1.5 s,
checks a stable paused clock and retains the same session. macOS behavioral RED
and GREEN are retained, followed by physical iPhone verification.

Both native probe and production public-view tests now unmount/remount while
retaining the same player. The probe keeps a second player active and checks
owner/epoch separation; seven-format production cases compare the actual paused
video/subtitle composition before and after remount. Session first-frame gating
remains unchanged: a current clear cue can precede native video presentation over
its black cover. This is not an assertion of a new view-revision gate.

## Evidence and limits

- [validation.json](validation.json): exact final passing runs, devices, counts,
  native-clock samples and open external acceptance conditions.
- [source-hashes.json](source-hashes.json): final changed source identities.
- [raw-evidence.tar.gz](raw-evidence.tar.gz) and [archive-manifest.json](archive-manifest.json):
  commands, stdout, failures, cleanup and original PNGs; every archived byte is
  rehashed after writing. The compiled macOS capture helper is excluded.
- [final-review.md](final-review.md): single independent review and executor
  disposition; 0 Critical / 0 Important / 1 Minor, test cleanup corrected.
- [execution-ledger.md](execution-ledger.md): decisions and task outcomes.

The iPhone screenshot route is Xcode CoreDevice's `device capture screenshot`,
with an explicit device ID, random-token bounded HTTP helper and explicit private
Mac interface. The user requested Device Hub observation; no Device Hub UI or
physical audio sensor was available. The physical recording API returned
unsupported ([retained output](p02-iphone-record.log)). No DRM frames were used.

Captured images establish visible composition, not sound, emitted luminance,
HDR color accuracy or physical A/V synchronization. The audio sequence uses
owned 440/660/440 Hz renditions and checks stable track identity and advancing
clocks; the user did not supply an audible observation. Native-clock cue samples
use nearest-rank p50/p95/max at n=14/platform; they are state-clock observations
after an engine frame, not a physical latency benchmark. A value of zero does
not mean zero display latency. No product performance target is inferred.

## Retained unsuccessful attempts

- Initial invocation used the wrong root-relative integration target; no case ran.
- First observation run tried to JSON-encode a session object; corrected to its
  public value. This was a harness failure, not a production failure.
- Next sequence exposed completed-state retention. macOS reproduced the same
  failure. Two guarded patch scripts rejected a non-unique edit before the
  correctly scoped change; repeated RED runs are preserved.
- Initial analyzer diagnostics were corrected; final affected analysis is clean.
- `iphone-20261020-004132`: 9/11, with WebVTT and TTML screenshot failures. PNG
  005/006 and 008/009 show the system volume HUD appearing/disappearing between
  samples. Strict difference assertions were retained. The same cases passed
  2/2 in `iphone-20261020-004612`; both runs remain in the archive.
- Final verification after independent immediate cleanup registration is listed
  separately in validation.json. Earlier runs froze only the available subset
  of test hashes; they are not represented as full source snapshots. The final
  iPhone run records all integration Dart sources, backend, native entry and
  capture helper; final changed sources also have a separate complete manifest.

The seven-format contact sheet is derived from final run iphone-20261020-005512
original physical PNGs 033/038/043/048/053/058/063:
[p02-formats-contact.png](p02-formats-contact.png). It is a convenience view; pixel
assertions and hashes refer to originals. PGS/VobSub intentionally use small
colored blocks; bounded ASS/SSA and TTML/WebVTT support remains as approved.

## Reproduction

Run the checked-in `p02_iphone_acceptance_test.dart` on an explicitly selected
physical device; start `tool/dash_timeline/capture_composition.py --platform
ios-device --device <id> --bind-address <Mac-private-IP> --output <folder>`, then
pass its URL using `--dart-define=P01_CAPTURE_URL=...` and its matching host using
`--dart-define=P01_CAPTURE_HOST=...`. Keep the example foreground and avoid system
volume overlays. Captured command JSONs contain the exact invocations used.

The archived scratch runners retain this host's paths/device identity for audit,
not portability. The temporary Homebrew iproxy wrapper is restored in finally
and verified by hash after each physical run. The owned Android emulator was
shut down after testing; the unrelated iPhone simulator was left untouched.
No push, merge, or changes to the separate P04 worktree are part of this delivery.

Additional physical DASH composition run passed 4/4: vtt/ttml/wvtt/stpp,
actual video marker RGB and cue glyph pixels at 0.5/2.5/4.5/5.5/7.5 s,
including the black cue-free Period gap, seeks and off clearing.
