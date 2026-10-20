# P07 → main 独立集成复审

审查者：fresh-context `/root/p07_main_merge_review`，gpt-6-astra/high。范围为 main `86143754` 合入 P07 `a0578861` 的暂存候选；只读、不运行测试或构建。结果 **Critical 0 / Important 0 / Minor 0**。

- main 的1,706个 packages 文件 mode/blob 完全保留，覆盖投屏、媒体拆分和P08包内改动。
- main 相对共同基线 `ab734051` 的40个变更路径，除总览追加及台账哈希更新外全部保留。P08计划、报告、历史证据未覆盖。
- P07的65个变更路径除总览外都与 `a0578861` 一致；总览保留main原文及P07两段完整内容，仅追加段前少一个空行。
- 两份P07历史SHA256SUMS共95项在原提交 `175145fc`/`a0578861` 全部匹配。当前只有总览因合并追加不同，历史清单保持原样。
- inventory.json 仅 evidence.p07.sha256 改变，绑定合入报告；source/rows/状态不变。现有输出 sourceMatches=true、currentPasses=0、releaseReady=false。
- P07 Task1、CAP-DV-MAP/OUT、完整映射与物理DV仍明确未完成，没有虚假提升。
- 暂存区无冲突阶段，工作树与暂存区一致，diff --cached --check通过。

边界：此为合并保留与证据绑定复审，复用P07此前实现复审；不替代另行执行的合并后统一测试。合并记录/新测试日志由主任务在原候选基础上追加，未变生产源码。
