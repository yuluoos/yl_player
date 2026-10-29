# Offline repeated-trial evidence

P04 Task 4A prepares aggregation; it does not perform measurements or freeze SLOs.
Requires Python 3 on POSIX (macOS/Linux): descriptor-relative no-follow opens protect
archive reads. No player, network socket, local server, Flutter or device is started.
The platform label describes the captured player, not the aggregation host.

Before measuring, save a conditions JSON object with exactly these fields:

```json
{
  "platform": "macos",
  "device": "owned-mac",
  "os": "macOS-27",
  "architecture": "arm64",
  "deviceKind": "physical",
  "buildMode": "debug",
  "sourceSha256": "<64 lowercase hex characters>",
  "artifactSha256": "<64 lowercase hex characters>",
  "dependencySha256": "<64 lowercase hex characters>",
  "profileId": "down-and-recover-v1",
  "profileHash": "<64 lowercase hex characters>",
  "mediaHash": "<64 lowercase hex characters>"
}
```

Replace example labels and hash placeholders with the measurement identity:
source snapshot, player binary, dependency inventory, served profile and generated
manifest respectively. Labels contain only ASCII letters, digits, dot, dash and
underscore (start with a letter/digit). These are declared conditions; hashing
capture files cannot verify device identity, cache treatment or binary provenance.
Archive the underlying identity evidence alongside the experiment.

```sh
python3 tool/playback_network/aggregate_experiment.py plan \
  --conditions /tmp/abr-archive/conditions.json --id owned-1 --attempts 5 \
  --cache-state cold --cache-state warm \
  --output /tmp/abr-archive/experiment.json
```

The plan predeclares auto/caps/fixed × cache states × attempts (at most 100 rows).
It does not prescribe execution order; interleave modes and record the actual
order in measurement notes. Omitting cache options uses `os-cache-uncontrolled`.
Only use cold/warm when the corresponding treatment was applied and documented;
a fresh server alone does not establish cold OS/player caches. Keep a frozen copy
of the pre-run plan. Different hardware/build/profile/media conditions require a
separate experiment. The manifest is mutable JSON, not a signed preregistration:
this tool can reject missing matrix rows, but cannot detect rewriting the entire
plan after the experiment.

For each row, use its run ID/mode in the [single-run protocol](capture-protocol.md).
Retain unsuccessful attempts. Set its `exitCode` to the actual player process exit
code and `artifacts` to three references (paths relative to the manifest directory):

```json
{
  "capture": {"path": "runs/owned-1-auto-cold-1/capture.log", "sha256": "<SHA256>"},
  "requests": {"path": "runs/owned-1-auto-cold-1/requests.jsonl", "sha256": "<SHA256>"},
  "serverStdout": {"path": "runs/owned-1-auto-cold-1/server.log", "sha256": "<SHA256>"}
}
```

Compute each SHA256 from the exact archived file bytes. Do not point at a saved
summary: aggregation recomputes each result from verified raw logs. Paths cannot
be absolute or contain dot/traversal components; symlinks and non-regular files
are refused. Per-file limits are 16 MiB for capture/requests and 64 KiB for server
stdout; each summary reads at most 256 MiB across trials. The CLI manifest limit
is 1 MiB. A trial reaching a limit remains invalid in the denominator. Inputs are
read-only; outputs use exclusive creation and never replace an existing file.

```sh
python3 tool/playback_network/aggregate_experiment.py summarize \
  --experiment /tmp/abr-archive/experiment.json \
  --output /tmp/abr-archive/report.json
```

Exit 0 means every planned trial is eligible for descriptive aggregation; 1 means
at least one was excluded; 2 means invalid manifest/output. `matrixComplete` has
this same narrow meaning, not platform/capability acceptance. Unrun rows remain
`not_run`; a recorded exit without logs remains `failed`. Missing, altered or
malformed artifacts remain `invalid_artifacts` with a bounded error code; raw
error text and capture contents are not echoed. The tool cannot reconstruct a
timeout classification from absent/corrupted logs; preserve its runner evidence
separately. Valid captures retain their own outcome even when excluded.

A valid run is eligible only if the single-run validator confirms process success,
cleanup and natural completion, no sampled policy violation, and successful media writes in each of the three network phases.
Legacy traces without phase counters remain parseable but are ineligible. Phase
coverage alone does not prove successful adaptation. Partial logs, nonzero exits,
timeouts, policy findings and early preloads remain counted. Distributions use
eligible runs only and always display planned/eligible/excluded counts and status
counts so that the denominator cannot silently shrink.

Each mode/cache cohort reports nearest-rank p50/p95 (`ceil(p*N)-1` in sorted values)
and observed/unavailable counts per metric. Unknown values stay null. These are
descriptive sample percentiles, not confidence intervals or a pass threshold;
with small N, p95 is usually the maximum. Metrics include captured first frame,
monotonic native rebuffer deltas, sampled geometry changes, written HTTP body
bytes, request failures and maximum sample gap. Geometry changes may be Period
changes; written bytes do not prove client receipt. Adaptation and end-to-end
latency remain unavailable because source clocks are uncalibrated.

All outputs retain `baselineComparable=false`, `capabilityAccepted=false` and
`physicalOutputVerified=false`. Real auto/caps/fixed baselines, native behavior,
live protocols/mode switching, frozen numerical targets and CAP acceptance remain
open. Synthetic unit fixtures prove report behavior only.

Offline checks (no socket tests):

```sh
(cd tool/playback_network && python3 -B -m unittest \
  test_aggregate_experiment test_summarize_capture test_prepare_fixture -v)
```
