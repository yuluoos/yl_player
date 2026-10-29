# P07 CM 扩展块与解码帧来源本地合并核验（2026-10-29）

按用户授权，将本轮已验证的 CM 扩展块继承和解码帧来源绑定提交并快进合并到本地 main。实现提交 `00be1a3a6993049d72cf9afb02bc4af031378a86`，main 从 `9687fab8736b4bc0a225058832069140c3b31efe` 快进，无冲突。合并树与已验收分支完全一致。本记录作为随后仅文档提交，不追加实现。

## 核验

| 检查 | 实际结果 |
| --- | --- |
| 提交前身份与证据 | 17 个候选文件哈希、原始证据清单、独立复审及报告绑定全部匹配 |
| 提交前定向回归 | CM 状态 8、解码来源 7、盘点/CLI 23，共 38 项通过 |
| 提交范围 | 57 个文件，仅离线工具、测试及记录 |
| 合并后 main P07 全套 | 101 项：100 通过，1 个既有 CGL 默认未启用跳过；启用宿主解码探针和 NumPy 2.3.5 |
| 合并后 main 台账 | 15 项通过 |
| 发布/性能结构检查 | 各退出 0，sourceMatches=true、releaseReady=false |
| 发布/性能 require-ready | 各退出 1，完整发布资格仍被阻止 |
| 播放器/依赖/CI | 与基线空 diff；git diff --check 通过 |

按集中验收规则复用与同一候选哈希绑定的 Rust 4 项、合成真实解析器检查、FEL 2908 对/P5 6314 帧完整来源核验及独立综合复审。合并没有改变实现，不重新执行长素材、GPU 或设备矩阵。

## 保留未完成项

[本轮实现与集中验收记录](2026-10-29-p07-cm-frame-provenance.md)及其原始 RED、测试、跳过、全片 trace、工具身份和复审证据完整保留。该报告中“未提交/合并”描述验收时快照，当前状态以本合并记录为准。

真实压缩视频/use_previous 来源、压缩 CM4/L254 固定库缺口、未知/保留 level、跨 ID/缺序列头/默认 DM、完整 CM/trim/NLQ/重采样/目标映射、FEL 同源独立目标与冻结容差、物理 DV 均保持开放。`effective_metadata_resolved=false`，CAP-DV-MAP/OUT 不提升。

P08 READY 同次因果链、系统 A5 资源上界，以及 P02/P03/P05 设备/最低 OS/硬件/热稳态/业务资格、P06 DRM 授权等按既有台账保留。P04 iOS 恢复由另一聊天处理；未修改其工作树、源码、设备或进程，未合入其分支，也未改写历史失败。

台账 102 行 implementation、verification、acceptance、nextAction 不变，只补合并证据引用：67 implemented、34 partial、1 unreviewed；30 external_missing、3 failed、69 not_run、0 passed。生产源码范围哈希仍为 `b4651f1fd23bf40cbc2384b2a0f39c0f0f90b0f736ca918b71aa25a895972eb5`。

[合并核验证据](evidence/2026-10-29-p07-cm-main-merge/)保存在仓库。本聊天工作树按既有宿主 primary checkout 保护保留，不绕过保护删除，不清理其他分支或工作树。未推送、未发布。
