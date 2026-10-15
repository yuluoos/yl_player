# P03 controlled evidence — 2026-10-14/15

This archive retains failed experiments as well as final observations. A log's presence is not a pass. Full CAP-FORMAT/CAP-DECODE and production software admission remain open. The execution ledger records RED/GREEN, stage commits, deviations and environment limitations.

## Final evidence entry points

- `android-task7-public-observations.json`, `macos-task7-public-observations.json`, `ios-task7-public-observations.json`: original public rows, source-log hashes, distinct-run rollups and explicit limitations. Public rows did not record the installed product build hash; they cannot satisfy the strict combined output envelope. Native PCM is separate.
- `android-output-native17.xml`: 17 actual native decoder/output tests, no skips. `logs/android-flv-route-green2.log`: 533 JVM tests, 530 passed and three preexisting skips.
- `macos-output-task7-final2-summary.json`: six actual pixel/PCM/consumed-clock/seek tests passed. `ios-output-task7-summary.json`: six tests failed, zero passed/skipped on the dedicated simulator. Required unavailable output is not an expected-rejection success.
- `software-measurement/result.json`: five optimized processes, 65 samples and 288 actual AV1 outputs each, plus six successful AVC hardware controls. Valid short measurement; no sustained thermal or independent product qualification. `protocol.json` binds inputs/builds before collection. Raw JSONL and stderr are retained, probe binaries/caches are not committed.
- `logs/dart-*-final.log`, `logs/analyze-*-final.log`: four Dart packages, 2003 tests passed and four clean analyses. `logs/analyze-integration-delivery.log` covers the final three public test sources.
- `logs/apple-contract-final.log`, `logs/android-contract-final.log`: installed artifact contracts. Apple canonical five-target reproducibility is recorded in earlier task manifests. Android uses the verified fresh three-ABI candidate; no independent full Android rebuild equality is asserted.
- `logs/discovery-task7-final2.log`: the three preexisting macOS fixture mirror differences remain unchanged. This audit is not claimed green.

## Reproduction commands

Run one platform runtime at a time. Use the project's existing native checks, Flutter examples and public Android wrapper. Apple format tests require the existing `tool/dash_timeline/capture_composition.py` service for the explicitly selected simulator/window; `run-plans/` retains the exact focus regex, additional arguments and test source hash. Slow capture is explicitly `YL_FORMAT_SLOW_CAPTURE=true` (0.25x); it cannot replace the retained 1x observations.

```sh
python3 -B -m unittest discover -s tool/media_matrix -p 'test_*.py'
python3 -B -m unittest discover -s tool/decoder_probe -p 'test_*.py'
python3 -B tool/decoder_probe/run_software.py tool/decoder_probe/software_protocol.json /tmp/NEW-P03-RUN
# From packages/yl_player/example, with the selected device and capture URL:
flutter test integration_test/format_matrix_test.dart -d DEVICE --no-pub --dart-define=YL_FORMAT_REQUIRE_SUPPORT=true --dart-define=P01_CAPTURE_URL=URL
flutter test integration_test/decoder_budget_test.dart -d DEVICE --no-pub
# Android only, via tool/run_android_integration.sh:
# integration_test/android_flv_route_test.dart
```

`manifest.json` records every other archived file's relative path, byte size and SHA-256. Verify these before consuming observations. It provides integrity, not an independent attestation or permission to generate an admission profile. Runtime summaries and raw logs are the evidence; the human report states which failures and external acceptance conditions remain.
