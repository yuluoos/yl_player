# iOS 清晰度策略与恢复竞争 Implementation Plan

> 当前工作树直接实施；沿用已授权的系统排障、测试驱动和集中验收，最终一次独立综合复审。

**Goal:** 自动恢复诊断必须尊重宽高上限和固定档位，并验证准备期间的新清晰度策略不会被旧恢复覆盖。
**Architecture:** 从既有peak-only判断提取诊断资格函数，先以原行为跑红灯，再加入尺寸/固定选择守卫。真实媒体在首票候选ready时通过既有backend替换接口提交320宽上限或固定低档；原item身份与新策略使旧候选失效。所有注入留在夹具中，不接入生产自动恢复。
**Tech Stack:** Swift/XCTest/AVFoundation与Python采集，已授权iPhone及macOS。
**Spec:** 前轮报告2026-10-28-ios-preparation-intent.md中的策略竞争未完成项；旧终末停顿已按用户要求移出，不再追踪。

## Constraints and Review Focus

基线024afebc。保持120秒素材、140/240秒期限、2秒准备、5秒票据、双8秒窗/3请求/955000bit/s、5秒缓冲、20秒剩余、两次预算/500与1000ms退避。新策略提交必须记录成功与实际item变化，失败不伪装成功。输出宽度和持续固定选择需原始帧/主行证明，采集passed不等于完整public-host或物理音画验收。保留所有失败，不合并、不推送、不发布。

- [x] 原峰值码率判定提取并接回automaticSample，新增资格/票据行为红灯；最小修复维度与固定档位守卫，镜像同步。
- [x] 新增caps-during-preparation/fixed-during-preparation，仅asset-preroll；Python先验证不匹配模式被拒绝。准备新策略资产使用同一冻结manifest快照，ready后同步提交，持有者转移/取消正确，主行记录尺寸/选择与资格。
- [x] 定向通过后同一制品依次caps、fixed、unconstrained auto-control、original-profile-control。仅验证本轮策略边界；不重复追踪已移除旧终末停顿，也不声称预滚带来性能收益。
- [x] 统一受影响iPhone/macOS原生、network/benchmark发现入口、镜像、证据完整性和台账；一次综合复审，完整原始xcresult归档，台账保留未通过能力状态，本地提交。

Ruling: 本轮先补已发现的诊断资格遗漏，并在真实媒体backend路径验证caps/fixed覆盖关系；公有host端到端矩阵、凭据竞争、物理输出及缺授权资源仍单独保留。

验收记录：四轮媒体均至片尾；iPhone171、macOS146、network116、benchmark294通过。独立复审无阻断，8个完整xcresult保留；发布台账维持releaseReady=false。
