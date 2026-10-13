# Fresh final review: MP4 elng bounded subtitle metadata

Read-only review; do not modify files, spawn agents, or run a duplicate full suite.
Workspace /Users/yy2021_8689/Desktop/Flutter/yl_player; base d6a23bf.
Review the entire uncommitted candidate slice, including untracked files, against
`docs/superpowers/specs/2026-10-13-subtitle-extended-language.md`.
Source/test ownership is in /private/tmp/yl_elng_validation.json. Snapshot is
/private/tmp/yl-elng-validation-n608pn27 (source identical to workspace), with ongoing
four-package suite /private/tmp/elng-final-four-packages.log and clean analysis
/private/tmp/elng-final-analyze.log. Directed 84 passed: /private/tmp/elng-directed.log.

Files: mp4_subtitles.dart, new mp4_language.dart; playback_session API doc;
test/support/mp4_fixture.dart, new elng_parser_test.dart (60), new elng_runtime_test.dart
(18), existing mp4_session_test.dart modified to exercise two scripts with same
packed language and distinct IDs. Docs: new spec, README, platform-support,
P02 overview subsection, CHANGELOG entry, new extended-language evidence only.
Full suite/evidence report still being finalized; do not grade missing final summary
while verification is actively running. Other P05/longplay/weakABR changes excluded.

Contract: optional single mdia/elng v0 flags0 ASCII one trailing NUL; max128 tag;
well-formed RFC5646 syntax + no duplicate variants/singletons; grandfathered/privateuse;
no registry/canonicalization; preserve casing; override valid packed mdhd; retain ID.
Rulings in P02 ledger (latest section): strict invalid-elng rejection, retaining prior
mdhd validation even with elng. Costs are rejecting salvageable files; no broad MOV
claim. TDD showed 57 failures/3passes before implementation (one boundary fixture
had length127 rather than128, corrected); initial green59/60 due hybrid stpp fixture
using a0..1cue for a1..2sample, corrected; directed84/84 now. Analysis infos corrected.

Review Focus (P02 plan, verbatim):
- 跨 Period 同语言不同 role/重复 ID：选择身份不能绑死数组下标（任务 1）。
- seek、切字幕、关闭、正负偏移：旧 cue/位图必须立即清除（任务 2/3）。
- 损坏字幕、字体/图形资源失败：独立错误且不偷偷决定视频存活策略（任务 2/4，PD-03）。
- 字体风暴、超大位图、ASS 动画/长文本：缓存及计算有界（任务 3）。
- HDR/DRM/外接几何改变：字幕颜色、位置与受保护视频边界分别验证（任务 4）。

Focus specifically on BCP47 syntax acceptance/rejection, count budgets, ranges,
atomicity, truthful API scope and meaningful tests. No native pipeline changed.
Return Critical/Important/Minor findings with file:line and reproducer; list any
behaviors declined to judge explicitly. Use requesting-code-review/code-reviewer.md
format. This is the one final review authorized by executing-plans skill.
