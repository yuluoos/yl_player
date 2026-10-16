# P03 PCM boundary and track-switch follow-up — 2026-10-15

Base: `094d7524eab956ca10f3b7af969ad6e347838524`. This closes a controlled portion of approved Task 7; full CAP-FORMAT/CAP-DECODE and production software admission remain open. No long-play or weak-network ABR work is included.

## Contract and reference

The new Matroska control copies video plus AC-3 5.1, E-AC-3 stereo, DTS stereo and FLAC stereo from four existing owned fixtures. Compressed packets are unchanged, verified individually. `p03-pcm-reference.json` pins source/fixture/PCM hashes, commands, all packet timestamps and frame counts, plus first/last and seek-window floats. Native tests use actual decoder output, with no waveform correlation or offset fitting. Every block timestamp/count, total retained frames, final end and unshifted first/last 4096 frames are checked (peak error < 0.0002).

| Control | Raw decoded frames | Programme start retained | Seek/switch at 2.5 s retained |
| --- | ---: | ---: | ---: |
| AC-3 / E-AC-3 | 192000 | 191760 | 71760 |
| DTS / FLAC | 192000 | 192000 | 72000 |

All controls are 48 kHz. Dolby packet PTS starts at −5 ms; clipping to programme zero removes exactly 240 frames. These are encoded-file boundaries, not a claim that lossy encoding retains every original input sample. Apple preserves AC-3 six-speaker order; Android uses its existing normalized stereo Lo/Ro. The latter reference explicitly uses host `pan` with L/R plus sqrt(1/2) center/corresponding side surround, excluding LFE. Host defaults use different normalization or embedded mix metadata; failed comparisons and the correction are preserved.

CoreAudio FLAC and host FFmpeg are different decoder implementations. Apple Dolby/DTS and Android share FFmpeg decoder ancestry with the host, so their oracle is separate-build regression evidence, not independent-decoder certification. Actual platform output and consumed-clock tests are distinct from physical speaker/A/V measurements.

## Fixes and failed experiments

- Apple packet-level seek filtering dropped the overlapping audio packet: 2.5-second E-AC-3 switching first exposed PCM at 2.523 seconds. Decode preroll first, then clip decoded PCM at sample precision; retain its full allocation charge and update queued timing.
- CoreAudio Dolby probes produced 191712 rather than 192000 raw frames and a phase offset. Prime modes, explicit prime information, packet frame declarations, direct AudioCodec and EOF drain did not recover the missing boundary. The existing minimal FFmpeg bridge now provides AC-3/E-AC-3 packet conversion with inspected speaker masks, bounded packet/output sizes, failure/reset semantics and native layout preservation.
- Android copied `initial_padding` into FFmpeg, which removed 256 frames without adjusting the JNI PTS; output clipping then removed time again. Dolby now requests manual skip so programme-time clipping is the sole owner.
- Newly linked E-AC-3 decoding required inclusion in the audio-only discovery whitelist to recover its encoded speaker layout. Software video remains excluded; real AV1/VP9 probe negatives verify this.

`progress.md` records rulings. Logs retain original RED, oracle corrections, a Swift compile failure and subsequent runs. File presence alone never denotes success. The old software-measurement archive is unchanged and bound to the previous bridge, not transferable to this build.

## Final verification

- macOS M1 / 26A434: **74 passed, 0 failed, 0 skipped** (`macos-final3-summary.json`), including actual converter boundaries, real backend switches, DASH rational clipping and related managed/audio regressions.
- Android API36 arm64 owned emulator: **22 passed, 0 failed, 0 skipped** (`android-native22.xml`), real JNI PCM and native playback/track-switch output.
- iOS27 / 24A434 owned simulator: **7 passed, 0 failed, 0 skipped** (`ios-pcm-final-summary.json`), actual first/last PCM, exact trim/allocation/reset, DASH negative clipping and existing Dolby layout/output controls. This does not exercise the hardware-dependent full-player track switch.
- Final bridge short protocol: **5 fresh optimized processes valid**, six AVC positive controls; each process verifies 288 real AV1 frames and 65 resource samples. `software-measurement/result.json`: `measurementValid=true`, `productionEligible=false`; peak RSS 15,777,792 B, footprint 7,881,280 B, total process CPU per repetition at most 190,131,000 ns. The frozen key binds the optimized probe and newly installed bridge. Missing sustained thermal evidence and independent product verification prevent production admission; this is not long-play qualification.
- Apple: independent clean rebuild matches every byte of 18 canonical entries across five targets. Accepted lock SHA-256: `87c426016bacbf4325678a8f22d9638127198ee78773e2f388345325427689e9`. Contract passes 3 slices / 5 architectures / 57 Swift symbols / 9 intended-reason negatives. Installed Dolby ABI passes 1035 checks, including production discovery, complete raw decode/reset and invalid-input behavior; peak error 0 for the complete raw controls.
- Android artifact contract verifies three ABIs, API24, JNI exports and current source identity; this turn relinks the existing verified static inputs and does not claim a new independent full-source rebuild.
- Python media/probe validation: 23 + 21 passed. No Dart/public API implementation changed; prior Dart results are historical, not rerun claims.

 The fixture mirror audit retains exactly three preexisting macOS differences (`AppleHostCharacterizations.swift`, `YlDashResourceLoaderTests.swift`, `YlMacosPresentationTests.swift`); it is not claimed green.

## Reproduction

Use one platform runtime at a time. `run-macos.json` and `run-ios.json` preserve exact xcodebuild selections; `run-native.py` executes them. Android runs `YlPcmOutputInstrumentedTest,YlFormatDecodeInstrumentedTest` with `:yl_player_android:connectedDebugAndroidTest` from its example Android project. `tool/media_matrix/prepare_pcm_alignment.py` explicitly regenerates fixtures; normal native tests consume pinned copies.

```sh
python3 -B tool/media_matrix/check_dolby_bridge.py packages/yl_player_apple/darwin/yl_player_apple/Frameworks/YlFFmpegBridge.xcframework/macos-arm64_x86_64/YlFFmpegBridge.framework/YlFFmpegBridge
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
sh packages/yl_player_android/tool/android_ffmpeg/test_build_contract.sh
python3 -B tool/decoder_probe/run_software.py tool/decoder_probe/software_protocol.json /tmp/NEW-P03-PCM-MEASUREMENT
```

`manifest.json` records archive hashes and byte sizes; `build-identities.json` binds native outputs/resources and current bridge inputs. Diagnostic raw PCM and xcresult bundles stay outside git, with hashes/summary logs retained. Full acceptance still needs the remaining formats/paths, same-run product-bound A/V evidence, actual iOS track switching on supported hardware, physical/minimum-OS/Intel coverage, AV1/Main10 hardware, sustained thermal evidence and independent product verification. Production admission tables remain empty.
