# P03 Task 7 Media3 VP9 bound A/V continuation

Base08f40e5acc3208a458fe86a73e201d898c84cf21. User authorizes current-environment remaining work, prioritize Android Media3 VP9 same-run build-bound A/V, API comments, verify/local commit. Existing approved P03 spec/plan Task7 and 2026-10-15 bound evidence contract apply; no new playback subsystem or renewed design approval.

Implementation: preserve frozen six controls; VP9 uses actual YlMedia3Engine/Core/renderer factory with test-only sink observation. Product defaults unchanged; internal nullable factory/surface seams permit real ImageReader and real AudioTrack-backed sink capture. Test recorder observes decoded PCM after Media3 trim and real AudioTrack head; no estimated currentPosition substituted. Single player, APK, media and run identities survive play/three seeks/completion/release. No production capture endpoint, no protected-content capture, no P05/long-play/ABR.

Preflight: Media3 sink clocks include output stream offset, encoder trimming and asynchronous flush. Observer must normalize once and invalidate on flush; seek phase cannot begin until seek acknowledgement. AudioTrack consumption must use freshly read head, not DefaultAudioSink smoothed time. Independent gate preserves route/codec evidence and old failed rows. Library instrumentation APK remains explicit scope, not public Flutter/release or physical output.

Steps: test gate/identity routing; native observation RED then minimal seam hookup; actual run with frozen APK and fixed six denominator; mutation/clock/flush checks; affected Python and Android suites; one final fresh review per executing-plans; archive hashes and explicit local commit. Preserve preexisting apple_flutter/__pycache__.

## Execution

- Gate RED: frozen Media3 route without initialized codec identities was accepted. GREEN: route mismatch/missing actual video or audio decoder identity now fails; 45 Python tests pass.
- Native RED APK `cfaaf9dcd96731c498d30c636170abd290c94a53349f74006808d6e78ec7b944`: observer seams declared but not connected; three preceding controls passed, VP9 produced no observations and hung on undrained texture cleanup. Explicitly stopped only the owned test process; incomplete scope remains failed. Install-before-boot failure is retained separately.
- Ruling: bound prepare/activate and disposal waits in the evidence harness — a failed observation job must not wait indefinitely; outputs are not released after an unacknowledged decoder disposal.
- Connected internal nullable factory/surface seams. Core still applies its codec selector/fallback policy. Engine and Core reject clear observation overrides for protected playback.
- First connected run APK `b05306cc70d49511b6947239c506ec3d84858fc65e06ec247555d03d8c5e25c0`: 5/6; Media3 initialized goldfish VP9 + Android Vorbis, but custom processor mishandled Media3's empty drain buffer (`source buffer is this buffer`). Focused empty-drain test reproduced failure before fix. Guard empty input before origin lookup/copy; no product playback change.

- Final connected run `f4793af8-aa96-4f7a-8de2-9c602973c5aa`, APK `8285316d8e8f0762141caf944743d778f574e15198432727e181698be4f0666c`: native + raw gate 6/6, no errors. Playback/three seeks each retain actual PCM, pixels, consumption clock; all outputs released.
- Same APK native regression 23/23 includes empty-drain GREEN. Negative build identity rejects before playback, no raw rows, scoped false. Android unit534/531pass/3prior skips, Python45pass.
- One fresh-context final review dispatched under executing-plans; no implementer delegation.
- Final fresh review found no Critical/Important/Minor issue; independent raw replay6/6 and negative0/6. No additional fix/re-review.
- User already authorized local commit; keep branch/workspace, no push/merge or integration confirmation needed. Preexisting Apple fixture __pycache__ remains excluded.
