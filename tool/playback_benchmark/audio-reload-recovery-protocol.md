# Explicit audio reload recovery

This bounded check exercises the real Apple typed Host Load transaction with
local AVC/AAC Matroska decoding and native AVAudioEngine output. It uses internal
dependency injection; the terminal candidate stays disabled by default at every
production constructor. No public schema, SDK, minimum OS or retry policy changes.

Two macOS tests in `YlMacosAudioTests` cover:

1. Play a local file until candidate audio submissions, native node time and the
   committed session's first video frame are observed.
2. Post an AVAudioEngineConfigurationChange notification scoped to that engine.
   Require exactly one safe render.audio_engine_failed event, failed state,
   stopped output, zero renderer-owned bytes, and no automatic reconstruction.
3. Explicitly Load the same source with a requested 1000 ms start position.
   Require a distinct session and output, candidate mode, a new first frame,
   fresh native audio time and advancing public media position.
4. Invoke a captured retired renderer failure callback and notify the retired
   engine again. Reject the old session's Play as session.stale. Require new
   playback to continue without another failure or new submissions to the old
   output. Resource-return callbacks from retirement may still complete.
5. In the second case, first reject a reload by disposing its actual native
   output immediately before Play. Require the safe non-retryable render error,
   no committed replacement and no automatic old-output rebuild. A subsequent
   explicit Load must recover as above.
6. Close the Host. All owned engines must stop and the shared managed ledger
   must return to zero. Save bounded audio branch counters/events as an XCTest
   attachment, along with output count and observed positions.

Retain failed attempts with their actual cause (test input/compiler failures
are not behavioral RED evidence). Final evidence includes native XCTest exports,
source/fixture hashes and shared iOS compilation. Never substitute this check
for the independent 1200-second zero-drop acceptance gate.

Limitations: the notification and disposed-output startup failure are controlled
within this test process. No actual system device is changed. This does not
prove physical audible output, real device-switch recovery, iOS runtime, a
whole-file EOF, or a global downstream resource bound. Candidate default and
production admission remain false.
