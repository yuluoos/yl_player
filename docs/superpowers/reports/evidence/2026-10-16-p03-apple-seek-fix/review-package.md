# P03 macOS public Flutter seek/readback continuation final review

Review read-only working-tree diff against base dea89b7d3c75638c0674605d56402d4aaecc1e89 (HEAD still base; local commit explicitly authorized after verification). Include untracked integration_test/support/paused_frame_capture.dart and example/test/paused_frame_capture_test.dart. Ignore preexisting tool/consumer_fixtures/apple_flutter/__pycache__.

User requests current-environment P03 remainder, prioritize macOS public Flutter post-seek pixel gap and native regression, API comments, verify and commit; avoid long-play/weak-network ABR. Approved spec docs/superpowers/specs/2026-10-14-p03-completion-design.md; plan docs/superpowers/plans/2026-10-14-p03-completion.md Task7 continuation. Broader P03 remains open.

Implementation and investigations: /private/tmp/yl-p03-seek-fix-20261016/progress.md, current source diff, durable evidence README (still being populated). Native41/41 passed incl real display pixel/clock test and corrected retirement test double. Flutter example74/74; Python48/48; analyzer/API check passed. public-final2 now raw6/6 plus framework/runtime identity/product stability true. All intermediate failures preserved including public-final4/6, clocks restoration failures, readiness RED. Same-bundle framework negative and variant/iOS compile checks still running; parent will verify before commit.

Specific review risks: temporary debug-only clock ownership, paused polling and cleanup, actual effective rate vs nil fallback, frozen-layer startup race, unaltered production admission, gate requiring new protocol and every pixel rate0, same-run/build/session identity, truthful scope docs. Keep metadata/parser conventions consistent; no need to re-review pre-existing media matrix/whole project. No production renderer changes.

Important deliberate boundary (Ruling lines in ledger): Apple default nil->host rate1, but assigning nil after custom clock makes internal rate0 (standalone clock diagnostic and native RED evidence). Therefore retain owned explicit host timebase at rate1 between snapshots until acceptance surface disposal; original stopped custom clock restored by identity, external replacement untouched. This is instrumented clear-content paused snapshot proof, NOT uninstrumented continuous presentation/physical sync/release/full P03. The SDK discourages custom clock + immediate frames generally; this instrumentation boundary must remain explicit. Decide by actual behavior and fail-closed evidence, not by pretending snapshot evidence proves physical output.

Plan Review Focus (verbatim):
1. 非零 Vorbis delay、首块 overlap、尾裁剪与回零 seek 组合：不能重复丢样本或把预解码音频提前播放（Task 1）。
2. 已知错误扩展名、无索引 PS、截断包和长时间戳 wrap：探测不依赖后缀，seek 不能只恢复 position（Task 2/7）。
3. 候选与当前 decoder 共存、多播放器争用及迟到回调：资源不漏记，旧帧不进入当前输出（Task 3/5）。
4. 高位深、superframe/隐藏帧、film grain、配置在中途变化：不因首个包可解而接受未经计量的新配置（Task 4/5）。
5. OS/依赖版本变化、未知热状态、进程被其他工作占用：旧测量不能自动准入新组合，不能把外层线程计量冒充全部 decode CPU（Task 3/8）。
