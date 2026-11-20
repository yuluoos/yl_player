# Native audio I/O period comparison

The workflow builds one macOS test binary and runs the full PCM sequence matrix
four times on the same hosted output device. The default-period runs bracket
two runs using the hosted matrix's larger device buffer. All four executions
use the same PCM, queue budget, EOF and completion checks. The test host owns
the temporary buffer setting and restores it after each execution.

`compare.py --io-period` verifies the actual pre-render slice sizes for each
matrix identity (512, 4096, 4096 and 512 frames, respectively). An empty
trace is allowed only for a zero-input row. Both 4096-frame executions must
pass. The original and restored runs retain their actual XCTest results in
the comparison receipt even if they reproduce the original failure.

[Hosted period comparison, run 5](https://github.com/yuluoos/yl_player/actions/runs/44677764884/job/136093586788)
used Apple Virtual Sound Device for all four executions. At 48 kHz, 512
frames give the renderer 10.67 ms per cycle and 4096 frames give it 85.33 ms.

| Observed period | Matrix result | Missing marker frames |
| --- | --- | --- |
| 512, before | Failed | Candidate 3-buffer sequence: 2,560 |
| 4096, first | Passed all 12 rows | 0 |
| 4096, second | Passed all 12 rows | 0 |
| 512, restored | Failed | Legacy 2000-buffer sequence: 21,312. Legacy starvation sequence: 572. Direct native controls: 1,012 and 804. |

The twelve matrix traces in each execution confirmed the requested period.
The hosted unit suite enables the larger device buffer for the lifetime of
this test in `tool/check_native_macos.sh`. The comparison verifies this CI
mitigation on the hosted device. It does not establish a latency setting for
end-user playback.

## Earlier device comparison

Running the diagnostic without the period option selects the original route
experiment. It builds on the same matrix and compares these output routes:

1. The runner's original default output.
2. The same default after installing the driver and restarting CoreAudio.
3. BlackHole 2ch, three separate test executions.
4. The original default again.

The original PCM sequence, zero-gap, EOF, completion-mode and buffer-budget
assertions remain in force. The test binary SHA-256 must stay identical between
arms. A successful diagnostic requires all three BlackHole executions to pass
with exactly the twelve existing matrix identities and no skipped test. It does
not replace the regular CI gate or establish physical speaker output quality.
Baseline failures remain in the comparison receipt and original xcresults.

`compare.py` refuses to install anything outside a GitHub-hosted runner. It
restores the original default output in `finally`; it does not change input or
system-alert routes. Each arm exports its attachments, test summary and log.
`comparison.json` binds them to the commit, test binary, Xcode, OS and route.

The official BlackHole 0.7.1 installer is fixed by URL and SHA-256, matching the
[Homebrew cask](https://github.com/Homebrew/homebrew-cask/blob/HEAD/Casks/b/blackhole-2ch.rb).
TLS verification and the digest check are required. The installer is downloaded
with curl because the vendor rejects Python urllib requests with HTTP 406.
CoreAudio is restarted only between tests on the disposable runner, following
the [runner image installation issue](https://github.com/actions/runner-images/issues/11746).

This comparison tests the hypothesis that the virtual machine's default output
clock contributes to the observed native sample-time jumps. BlackHole's
[`GetZeroTimeStamp` implementation](https://github.com/ExistentialAudio/BlackHole/blob/v0.7.1/BlackHole/BlackHole.c#L4121)
derives its timestamp series from the guest's monotonic clock. Changing that
route still uses the real-time AVAudioEngine/HAL graph; it is not manual or
offline rendering. Results must be read before adopting any CI configuration.


## Recorded results

Each cell counts full matrix executions that passed. The three default-route
executions cover the original output before installation, after the CoreAudio
restart, and after restoring the original route.

| Run | Runner | Default route | BlackHole 2ch |
| --- | --- | --- | --- |
| 2 | macOS 15.8.2 arm64 | 0/3 | 1/3 |
| 3 | macOS 15.7.9 Intel | 1/3 | 1/3 |
| 3 | macOS 26.7.2 arm64 | 1/3 | 1/3 |
| 4 | macOS 15.7.9 Intel | 0/3 | 1/3 |
| 4 | macOS 26.7.2 arm64 | 0/3 | 1/3 |

The three comparisons in runs 2 and 3 passed the first BlackHole execution.
In run 4, Intel passed the second execution and arm64 passed the third.
No environment achieved three consecutive passes. Run 1 ended during driver download after the baseline execution.

The archived verifier pairs each PCM attachment with a native trace, checks
the twelve matrix identities per execution, and recomputes the intersections
where both clocks share an observed origin. To reproduce the Intel result from
the repository root, run

```sh
python3 -B docs/superpowers/reports/evidence/2026-11-11-ci-gates/analyze-device-comparison.py \
  audio-device-diagnostic3-macos-15-intel --verify
```

Use the same command with `audio-device-diagnostic1`, `audio-device-diagnostic2`,
`audio-device-diagnostic3-macos-26`, `audio-device-diagnostic4-macos-15-intel`, or
`audio-device-diagnostic4-macos-26` to verify the other archives. The report
records where the timestamp alignment required for a loss calculation was
unavailable. [CI gate report](../../docs/superpowers/reports/2026-11-11-ci-gates.md)
