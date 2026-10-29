# Independent review — half-close characterization

Baseline: `2e3e2793`. Reviewed the uncommitted test/consumer-count changes and `docs/superpowers/plans/2026-10-29-half-close.md`; production source was read for control-flow verification. No source files were edited and no device tests were started by this reviewer.

## Finding

**P2 — Stabilize the cancellation outcome before making it mandatory.** `tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashResourceLoaderTests.swift:4093,4126–4129` (also both generated example copies): the origin immediately returns the response, while the proxy observation must always have `cancelCause == 2` and `outcome == 1`. If the initial receive gets the complete HTTP request without the EOF, the implementation resumes the URLSession task and only then installs `monitorDisconnect`. The upstream completion path and the subsequent EOF callback can race; `finishProxyResponse` may seal a successful terminal row first. Ignoring byte counts does not remove that terminal-outcome race. This can fail the new matrix test on unchanged production behavior. Hold the proxied origin response until the EOF cancellation/trace settles, release it in guaranteed cleanup, and state explicitly that this controlled response timing isolates EOF behavior. Alternatively, make the characterization genuinely observational and stop claiming cancellation is a guaranteed result of every scheduling outcome; do not silently broaden acceptance claims.

## Scope and evidence limits

- Production control flow supports the local mechanism: `receiveRequest` and `monitorDisconnect` map a received EOF to `close(... diagnosticCancelCause: 2)`; `close` removes ownership, finishes the downstream trace and invokes `task?.cancel()`.
- The direct/proxy client uses `.finalMessage` and continues receiving before any explicit local `cancel()`. Direct success can demonstrate that this client action need not mean response interest has ended.
- `outcome == 1` is the proxy's downstream termination classification. `taskOutcome` is separately recorded by the Foundation completion callback. An ungated fast response may have already completed upstream; do not equate the proxy cancellation classification alone with an effective upstream task cancellation.
- This does not establish what historical AVPlayer sockets did, explain any historical two-transaction sequence, or prove all full-disconnect resources remain bounded after a prospective behavior change.
- No production EOF-branch removal is safe to approve from this evidence alone: a change needs an explicit alternative cancellation authority or bounded reclamation design and its ownership/resource validation.
- The three test copies and expected-case increase are within test maintenance scope. All capability/half-close/historical-proof flags remain false. Existing readiness, long-fixture and failure limitations must stay unchanged.

## Validation status

At this initial review checkpoint the macOS selected run returned exit code 0; consumer log reports 46 tests with one skip and tools log reports 200 tests. Native attachment extraction, exact identities/result binding and final evidence review are pending. These observations are not a claim that the reported P2 race occurred during a run, or a substitute for the final xcresult verification.

## Final same-review disposition

**No remaining blocking findings for this test-only characterization and bounded report. P2 resolved.** The final source adds a per-iteration semaphore and a guaranteed `defer` release; only the proxied origin response waits (up to eight seconds), so it cannot win the terminal-outcome race during the test's earlier receive/capture waits. The direct response remains immediate. The test does not wait for a server request before sending EOF and therefore does not force a cancelled request to reach the server. No production behavior was changed.

A nonblocking stale comment still says upstream response and EOF can race next to the byte-count policy. The final report explicitly distinguishes this from the gated implementation and does not use it as evidence. Keeping byte counts observational is harmless; the comment should be corrected in ordinary maintenance.

I inspected the final report, all four exported attachment payloads and their manifests, and verified each payload equals its corresponding `observations.json` entry. All four runs show a 67-byte direct HTTP response with the expected four-byte body and a zero-byte proxy response; each proxy row has `cancelCause=2`, downstream `outcome=1`, and Foundation `taskOutcome=1`. The initial iOS run records one transaction with zero reported request/response bytes and unavailable timing boundaries; initial macOS and both gated confirmations record zero transactions. Zero transactions do not supply measured byte counts and do not prove any historical server-arrival behavior.

The preserved pre-gate selected matrices passed iOS 253/253 and macOS 228/228, with no skips. Their exact-identity binding files list 253 and 228 expected/observed identities respectively. The final gated method passed 1/1 on each platform. This is focused selection, not all 880/924 registered cases. I verified that the pre-gate source snapshot differs from current files only in the three mirrored test files, and that every present path in the final source snapshot matches its recorded SHA-256. Reusing the unchanged selected methods while rerunning the changed method is appropriately described in the report.

Tools report 200 passing tests. The final consumer rerun reports 46 tests, 45 passing and one retained historical-evidence skip; its fixture equality check passes. The readiness receipts retain `sourceMatches=true`, `releaseReady=false` and expected exit 1 for both require-ready checks. Direct baseline/current comparison confirms all 102 implementation/verification/acceptance row values are unchanged. The inventory only adds the new report, rotates the latest iOS evidence reference and updates its next action.

The final report accurately keeps the production half-close defect, safe cancellation authority/bounded reclamation design, historical AVPlayer causality, and other acceptance gaps open. No new long-media capture is claimed. Approval here is limited to preserving this reproducible diagnostic observation and its test-race correction; it is not approval of a production cancellation change or a release. Original xcresult archival is being performed by the coordinating agent; this review independently checked the live raw exports and result summaries, not a future completed archive.
