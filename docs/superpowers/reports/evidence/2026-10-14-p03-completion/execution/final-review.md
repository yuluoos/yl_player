# P03 final independent review

Reviewer: gpt-6-astra, fresh context, read-only, no nested agents or native runtime. Range: 964a7c07303bd095b8504e376f3de6409a4a6cd9..945a31582718431c460e05693a12c026d918a508. Verdict: With fixes. No Critical or Minor findings; three Important/P2 findings.

1. **Legal QuickTime without ftyp rejected.** Automatic .mov now undergoes bounded inspection, but only a first ftyp atom is recognized. Preserve bounded content inspection while accepting legal legacy movie atom layouts. Test equal-size ftyp-to-free transformation of the owned MOV through automatic local/HTTP load and first frame. Locations: YlEngineRouter.swift:77, YlSourceInspector.swift:62.
2. **Native Android startPositionMs not applied to demux/output.** Owned AVI/finite FLV routes initialize a timeline value but still decode from zero; audio then anchors at zero. Apply real seek and presentation floors before first output. Test 2500ms start with actual blue pixels and PCM target times. Locations: YlProgressiveExtractors.kt:24, YlNativeFallbackEngine.kt:97.
3. **Native audio switch misses full seek reset.** New PCM output lacks target floor, hardware video is not flushed, seek failure is ignored. Reuse the real seek transaction's target clipping, video flush, generation and clock reset; handle failure. Test a dual-audio AVI at a non-keyframe point using real output. Location: YlNativeFallbackEngine.kt:314.

Strengths: production admission stays closed; shared ledger covers retained frames across decoders; evidence separates output, failures, simulator limitations and qualification.

## Declined to judge

- Physical A/V, minimum OS, Intel, AV1 hardware and sustained thermal: no matching environment; existing CAP gaps remain.
- Long-play, weak-network ABR, P05: explicitly excluded by user.
- Repeating independent native rebuild/runtime evidence: review prohibited builds/runs; source and retained evidence inspected only.

Author accepts all three Important grades. Each enters the single RED-to-GREEN fix pass. No second review is requested. See progress.md for actual fix tests and final verdict.

## Author verification and final disposition

All three findings addressed in one fix pass. MOV actual file/HTTP RED2→GREEN2, macOS related62/62 and iOS6/6. Native Android initial PCM0, switched PCM1.08s and ignored seek failure each reproduced, then actual PCM/frame/colour assertions passed; full native20/20 and JVM530passed/3preexisting skips. Public resume2/2 passed both before and after: finding2 is specifically a direct native adapter contract defect; the managed wrapper already applies the seek. Additional real dual-AVI initialization failure identified mixed3/4-byte CSD; existing payload-preserving normalization now also applies at configuration, and the real decoder succeeds. No Critical/Important remains from this review, no deferred minors, no second review. Final public seek smoke and commit are recorded in progress.md.

Final five-path actual-output regression:5/5 passed. Final targeted public-test analysis clean. Author fix-pass gate is complete; external CAP gaps and closed production admission remain.
