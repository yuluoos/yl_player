# Real decoded natural EOF and tail drain

Use the existing 4.021-second local `format_matrix/mkv-avc-aac.mkv` fixture:
AVC video and 48 kHz stereo AAC. Record its probe and SHA256. Start at the
beginning, use real Host Load, demux, decoders, native audio output and texture
publication; observe completion before closing the Host. The mixer is muted.
The internal candidate is explicitly enabled only for this test.

Two cases:

- Natural EOF: pass the native tail callback through without delaying it.
- Held tail: retain one actual native playedBack callback after the system has
  delivered it. During the hold, renderer pending/owned bytes must remain
  positive and no completed state may appear. Pause, forward the held callback,
  wait for pending/owned bytes to clear, and require paused state with no
  completed publication. Resume, then require completion.

At the public completed callback, capture monotonic timestamps, output counts,
renderer bytes and pending state. Require exactly one native playedBack and one
forward, in that order before the observed completed publication; one playedBack
submission, more than one rendered submission, and every rendered resource
callback received. The renderer must have zero owned bytes and no pending
playback, the candidate must still be enabled, one first frame must have been
published, and no playback failure may occur.

The held case replays the retired tail callback twice after completion. Verify
renderer pending/bytes, completed state and failure/completed publications remain
unchanged. After Host close and settling, replay again and compare every public
callback kind's count. Require all output stopped and managed ledger zero.
The gate holds only a callback closure, no media buffer; counters/times are bounded.

Retain the initial result and the final result after review. Run the audio class
plus existing controlled session EOF cases covering equal, longer audio and
longer video tails. Verify canonical macOS fixture parity and test discovery.
There is no production or iOS source change, so no repeated full native suite,
iOS build or 1200-second run is needed. Earlier long-run evidence keeps its
original source/binary identity; do not relabel it as a result of this test build.

This proves completion ordering for this finite real-decoded file and the
controlled pause/forwarding case. It does not prove physical audibility, actual
device-switch recovery, all formats, minimum OS/Intel/iOS runtime, or a global
downstream memory bound. Default candidate enablement and admission remain false.
