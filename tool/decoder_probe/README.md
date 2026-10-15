# Apple AV1 decoder feasibility probe

`run_apple.py` probes actual VideoToolbox sessions on the current Mac.
The separate controlled software measurement tool is documented below.
It does not enable a production decoder, define a software budget, measure
performance, or verify physical output quality. It supplements P03 Task 3;
P08 A/B measurements are still prerequisites for software admission.

Run from repository root with access to the system VideoToolbox service:

```sh
python3 -B -m unittest discover -s tool/decoder_probe -p 'test_*.py'
python3 -B tool/decoder_probe/run_apple.py /tmp/yl-decoder-new-run
```

Use a new output directory every time. The runner checks fixture and owned-source
SHA-256 values, compiles the Swift probe with `-O`, and retains the binary hash,
source identities, device/OS, raw rows and result. Each fixture process has a
30-second deadline. Timeout, setup failure, incomplete rows or a failed AVC
positive control leave a failed result and retained partial logs; they do not
produce a capability conclusion. Exit 0 means a complete evidence collection,
including unavailable decoders, **not AV1 playback support**.

The matrix is three fixed 320×180 inputs × three policies × two sequential
session creations (18 observations). AVC Constrained Baseline 8-bit is a positive control;
AV1 Main 8-bit and Main 10-bit probe the missing route. The second creation is
an independent native recreation, not a product seek/Period transaction.
Every successful session records the strict CFBoolean hardware property,
decode/flush/wait statuses, output frame count, geometry and pixel formats.
A hardware hint alone cannot pass. All expected frames and error-free output
are required for a `av1HardwareDecodeObservations` count. Only native -12906
(`kVTCouldNotFindVideoDecoderErr`) counts as unavailable; -12911 malfunction
is a separate creation failure and may reflect sandbox/service restrictions.
The AVC control must succeed for all policies and recreations.

Fixtures contain compressed packets and original codec configuration extracted
with host FFmpeg. Regeneration requires host `ffmpeg`/`ffprobe` and libsvtav1:

```sh
python3 -B tool/decoder_probe/prepare_fixtures.py
```

The manifest retains exact hashes, source paths, profile/depth/frame counts,
FFmpeg version and the 10-bit derivation arguments. The 10-bit input is an
upconverted re-encode of owned 8-bit colors: it tests 10-bit sample storage,
not native 10-bit precision, HDR or color fidelity. Regeneration may change
encoded bytes across encoder versions; verify and review changed hashes.
The host software decoder checks fixture validity, not production soft decode.
No FFmpeg runtime module or commercial SDK is added to the player.

`macos-av1-observations.json` records the M1/macOS 27 run. Other Apple devices,
iOS and Android remain unmeasured by this tool. A device with a decoder still
needs product integration, actual output validation, policy/rebuild tests and
P08 resource/thermal baselines. Apple documents AV1 decoding in the M3 family:
[Apple M3 announcement](https://www.apple.com.cn/newsroom/2023/10/apple-unveils-m3-m3-pro-and-m3-max-the-most-advanced-chips-for-a-personal-computer/).
Do not generalize this M1 result to all Apple hardware.

`software_evidence.py` validates the separate P03 software engineering protocol:
five distinct processes, 2 seconds idle, 12 seconds decode/output, 2 seconds
dispose, complete 250 ms samples, exact protocol/build/fixture identities and
actual output/positive-control success. CPU is cumulative process CPU including
worker threads. Missing, duplicate, nonmonotonic, unknown thermal or failed rows
remain invalid. Debug/simulator measurements cannot qualify production.
The short protocol always reports missing sustained thermal and independent
verification evidence; a supplied boolean cannot open production admission.
It writes no profiles. Synthetic validator tests are not device evidence.

## Fixed software engineering measurement

`run_software.py` measures the installed Apple AV1 bridge in five fresh,
optimized processes. Each process has 2 s idle, 12 s paced decode (288 actual
NV12 outputs) and 2 s after disposal. The 65 raw samples contain actual monotonic
time, cumulative process CPU, resident bytes, physical footprint, thermal state
and low-power state. Process CPU includes decoder workers and probe overhead.
The fixed 50 ms sampling lateness bound is declared before collection; timestamps
are never rounded to an ideal grid. A separate fresh AVC VideoToolbox positive
control must output all frames before measurements begin.

```sh
python3 -B tool/decoder_probe/run_software.py \
  tool/decoder_probe/software_protocol.json /tmp/yl-software-new-run
python3 -B tool/decoder_probe/run_software.py --check-admission \
  /tmp/yl-software-baseline /tmp/yl-software-independent-verification
```

The output directory must not exist. The runner freezes the exact protocol,
fixture, executable and loaded bridge hashes before execution, preserves partial
raw failures, and rejects reordered/missing/duplicated samples or changed source
and binaries. Admission checking is read-only: copied processes, changed inputs
and summary rows that differ from raw output cannot qualify a verification.

These are short engineering measurements of actual pixel buffers, not physical
display, speakers, sustained thermal qualification or the Flutter product binary.
The 32 MiB/64-frame ownership limits are fixed test limits, not measured production
profiles. The tool always leaves production admission disabled. Matching sustained
qualification and actual product-build verification remain separate requirements;
this tool does not start long-play or weak-network workloads.
