# Frozen audio adapter integration protocol — 2026-10-08

Base: `3847021713a4f4c78583919a483bc70086e3dd74`. Default candidate stays off;
adapterImplemented=true, productionAdmission=false, downstreamBoundProven=false.
This protocol is frozen before the first actual adapter run. Each build/run gets
its own source/test/protocol/native executable hashes, command and environment
snapshot under `/private/tmp/yl-audio-integration-*`; failed attempts remain.
No physical-output, minimum-OS, Intel or unavailable-device pass is inferred.

## Workload and gates

Use the production YlAudioRenderer and YlSystemAudioOutput, with an injected
AVAudioEngine solely to observe the existing player node. Same graph, 48kHz,
stereo Float32 planar, 1024 frames/buffer, rate 1, final mixer muted. Tap only
channel 0 at the player output; this precedes time pitch/mixer/device/speakers.
A bounded-memory observer checks each nonzero frame in sequence using exact
Float32 marker `(frameIndex % 2097152 + 1) / 4194304`. The 2^21 period keeps
values exactly representable; final total-frame equality also detects losses of
whole periods. Ignore leading/trailing zero padding; count every interior zero.
Keep scalar totals and bounded error examples, never retain all long-run PCM.

One planned paired legacy/candidate matrix: 0, 1, 3, 2000 buffers; 100-buffer
sequence with 300ms refill starvation after 40 buffers; in-flight pause followed
by EOF and resume. Each arm uses a fresh renderer/engine. Ordinary candidate
submissions use renderedResource; the final EOF uses playedBack. All submitted
frames must be received once in order, no unexpected failure, no premature drain,
owned budget <=196608B/24 buffers and zero after dispose. Steady 2000-buffer arms
require zero interior zeros; starvation/pause retain gaps and require all frames,
not gap-free output. Starvation must cause one-way compatibility in the candidate.
Timeout: scheduled media duration + 10s. No retry changes a failed attempt to pass.

Separate real-adapter reset/generation, rate and configuration-notification tests;
configuration notifications are injected for this deterministic check, not a claim
of physically changing the device route. A genuinely unavailable/disposed system
output verifies existing safe engine-start failure fields. Real AAC conversion
uses the checked-in benchmark_sdr.mkv hash. Real session uses opus_switch.mkv,
real demux/audio converter/system output with controlled video/display; this
isolates audio integration without claiming VideoToolbox/physical AV acceptance.
Missing/old callbacks must never synthesize completed. Run full macOS suite once
on final source plus iOS simulator build; retain every failure/skip.

## Independent long continuity and resource observations

After the short matrix, one candidate-only single-generation stream runs >=1200s
without pause, reset, seek, reload, looping a player, MallocStackLogging, heap,
vmmap, or build workloads. The synthetic marker generator is finite (>=1205s of
PCM), not a tool queue model; production renderer/driver remain in the path.
The paired short and resource arms are the legacy comparison; this long run is
an absolute continuity check, not a legacy/candidate long-run performance ratio.
Observe each 5s: uptime, marker progress, renderer media clock, pending/owned PCM,
RSS/physical footprint, thermal state, PID/generation, mode/callback totals.
Reuse P08's >=1200s, <=7.5s cadence gap, 90–110% per-interval progress and <=5s
cumulative drift gates after >=2s warmup; zero sticky errors and zero interior
zero frames. A gap/failure stays failed while evidence collection may finish.
Deadline 1320s after play, command 1500s. Dispose and take two post samples >=2s
apart. No resource-growth threshold is invented after observation.

Run resource collection separately, paired legacy/candidate, 2000 buffers each.
At configured, mid-playback (>=1000 accepted), drained and disposed checkpoints,
record RSS/footprint and `heap --noContent` counts for owned PCM, callback shells
and dispatch sources, including raw tables and missing types (not fabricated 0).
These checkpoints deliberately perturb playback; no continuity pass is derived
from them. Hold at most 30s for each explicit collector acknowledgement, failing
missing slots. Owned limits come from the renderer budget (196608B/24); OS/system
allocations have no established upper bound, so downstreamBoundProven stays false
unless independent evidence establishes one. No performance ratio or leak verdict.

Record macOS/Xcode/architecture, actual audio device/format, AC/battery and thermal
state before each workload; environment/route changes remain in the report.
Caffeinate assertions are temporary; do not alter system power preferences.
EOF requires actual final playback notification plus all resources returned.
EOF after the long interval does not count toward the >=1200s interval.
