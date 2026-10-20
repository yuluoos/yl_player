# remaining-engineering 合并 main 验证证据

合并提交 `b24282a5d5812237b5c15a7f425a0a4ed264b629`，最终代码修订 `0e0e3066f887deb6037855cfcbdaf26705cec5c8`。整体发布仍未通过。

- `validation.json`、`full-run-comparison.json`：本轮全套、与历史失败的逐项对比、定向修复及最终覆盖依据。macOS 首轮859通过/1失败，修复后累计860有通过证据；iOS779通过/33失败/1跳过，严格门禁仍失败。
- `preflight.json`、`final-preservation.json`：合并树与分支一致、生产588条源码清单、旧229条证据哈希及未覆盖现有成果的核对。
- `foundation-command.json`、`foundation-summary.json`、`foundation.log.gz`：显式开启 HEVC 探针的完整基础矩阵，635项Python中1项可选CGL跳过，Dart2331通过。
- `native-commands.json`、`macos-recheck-commands.json`：真实构建、测试、结果门禁命令、退出码和时长。
- `macos-results/`、`ios-results/`、`macos-recheck-*-results/`：实际XCTest身份树、摘要、严格门禁收据；iOS跳过活动与能力附件。
- `*-failure-details/`、`macos-failure-activities.json`：首轮macOS唯一失败以及iOS全部33项失败详情。首轮／中间失败没有移除。
- `*-diagnostics/`：各轮XCTest诊断及真实控制台；`*-attachments/`：macOS资源／EOF及iOS FLV能力附件。
- `test-wait-fix.patch.gz`、`independent-review.md`：只改测试等待条件的修正和定向复审记录。
- `release*.json`、`thresholds*.json`、`readiness-commands.json`：完整未完成能力、nextAction和阈值清单；结构有效，两个require-ready仍退出1。
- `environment.json`记录一次受沙箱限制的Flutter版本读取及随后成功重试；它不是测试失败。xcresult的通用console接口未提供日志，随后通过diagnostics成功导出真实StandardOutputAndStandardError。
- `verification-manifest.json`绑定每份导出资料的原始、脱敏内容和压缩哈希；`SHA256SUMS`绑定当前全部版本化证据文件。

日志仅脱敏本地用户路径、UUID及运行token，保留数值、测试身份、断言、失败、跳过与警告。UUID采用稳定哈希映射，保持附件引用一致。JSON/text压缩后需解压阅读。未提交完整xcresult、DerivedData、媒体或framework。原始运行包保留在 `/private/tmp/yl-remaining-main-merge-qiu5k5ok`。

全套加定向回归不写成一次全套全绿；公开回调计数、资源、suspend/resume及重播断言没有弱化。P04/P07/P08和其他外部验收缺口全部延续，完整清单见本轮报告、release/threshold输出及原工程报告。
