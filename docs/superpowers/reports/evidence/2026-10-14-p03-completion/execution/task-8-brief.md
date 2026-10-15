## Task 8: P08 必要测量、准入复验和最终交付

**Files:**
- Create: `tool/decoder_probe/software_protocol.json`, `run_software.py`, `software_decode_probe.swift`
- Modify: `tool/decoder_probe/software_evidence.py`, `test_software_evidence.py`, `README.md`
- Modify: new Apple/Android admission manifests only when evidence qualifies
- Modify: `docs/superpowers/reports/2026-09-26-remaining-03-formats-decoding.md`, original P03 plan, `2026-09-26-remaining-overview.md`, `docs/platform-support.md`
- Create: `docs/superpowers/reports/evidence/2026-10-14-p03-completion/` (explicit logs/manifests/ledger/review files only)

**Interfaces:** `software_evidence.summarize(protocol: dict, rows: list[dict]) -> dict` returns measured summary and explicit admission blockers. `run_software.py PROTOCOL NEW_OUTPUT_DIRECTORY` never overwrites a run. A profile generation command consumes baseline and distinct verification run hashes and refuses incomplete/unqualified evidence.

- [ ] Freeze a controlled baseline protocol before running: five fresh process repetitions, each idle 2 s, owned decode/output 12 s, dispose 2 s, monotonic resource samples at 250 ms, no excluded warmup/retries. Decoder runs optimized with fixed thread counts and fixture/build hashes. This short protocol measures engineering overhead; `sustainedThermalVerified=false` remains explicit and prevents standalone production admission.
- [ ] Measure true process CPU/RSS/footprint, system power/thermal state and output correctness. Account internal decoder workers; process CPU is conservative and labelled if per-decoder attribution is unavailable. Test collector with truncated/duplicate/out-of-order samples and a failed positive control before accepting a run.
- [ ] Consume any already qualified matching P08 sustained evidence read-only. If absent, finish engineering/controlled validation but retain production software profile as unadmitted with exact missing input; don't launch the other chat's long-play workload or invent thermal thresholds.
- [ ] When a baseline qualifies, freeze limits and profile identity in a reviewed evidence manifest before a new independent verification run. Verify real playback at the admitted boundary and synthetic one-unit-over accounting failures. Build/OS/device changes invalidate that record until remeasured. Preserve a failed verification as a failed profile, not a tuned-after-the-fact pass.
- [ ] Run final affected Dart suites from repo root, keeping heavy native builds separate:

```sh
flutter test packages/yl_player_platform_interface/test --no-pub
flutter test packages/yl_player/test --no-pub --concurrency=2
flutter test packages/yl_player_apple/test --no-pub
flutter test packages/yl_player_android/test --no-pub
python3 -B -m unittest discover -s tool/media_matrix -p 'test_*.py'
python3 -B -m unittest discover -s tool/decoder_probe -p 'test_*.py'
python3 -B tool/media_matrix/catalog.py
sh packages/yl_player_apple/tool/apple_ffmpeg/test_build_contract.sh
```

  Run four-package analyze, public API/pigeon checks if their inputs changed, and impacted native audio/FEL/P01/P02 suites. Repeat only after a change/failure warrants it. Record original failures and environment workarounds separately.
- [ ] Produce one final review package with base/head, approved spec, this plan, Review Focus, ledger rulings and evidence. Dispatch one fresh reviewer as required by executing-plans; fix Important/Critical findings with RED→GREEN and affected regressions. Deferred minors are recorded.
- [ ] Update every relevant plan checkbox from actual evidence, archive ledger and review, and commit explicit final files. Report commits, tested functionality and remaining external acceptance conditions without calling all P03 complete while required evidence or implementation remains open.

## 自查覆盖与执行记录要求

设计中的容器/音频由 Task 1/2/6 覆盖，解码接口/AV1/VP9/FEL 保持由 Task 3/4/5/6 覆盖，managed/旧系统/错误扩展名由 Task 2/5/7 覆盖，资源/测量由 Task 3/8 覆盖，完整输出/跨计划回归由 Task 7/8 覆盖。五项 Review Focus 均有对应失败测试。

开始时使用本计划自己的 `.superpowers/sdd/2026-10-14-p03-completion/` ledger；不得读取或复用另一计划的工作目录。每项记录真实 RED/GREEN 命令、日志路径、fixture/build 哈希、通过/失败/跳过数及限定文件提交。当前共用 checkout 的明确文件提交方式延续 P02；检查 HEAD 和文件摘要后提交，避免把另一会话的改动带入。
