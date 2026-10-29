# P07 trace 发布修复：本地合并与清理（2026-10-29）

按用户“合并到 main 后清除”执行。修复提交 `3818dbb768c23d7bce61c0c727ba4c1faf3710ed`，本地 main 从 `ac482e573b4f0a2cb25e8e012eec8fe24698dc19` 快进至该提交。未推送、未发布，未修改另一聊天 iOS 工作树。

提交前复核全部候选源码和证据哈希，8 项定向发布回归通过。合并后在 main 重跑 P07 全套：128 项，127 通过、1 项既有 CGL 跳过；台账 15 项通过。发布与性能结构检查退出 0，require-ready 均退出 1；完整发布资格仍未就绪。产品、依赖和 CI 无本轮改动。

本轮分支 `codex/p07-trace-publication` 已安全删除。应用归档接口返回 `The task's primary checkout cannot be removed.`，所以保留本聊天受保护工作树并切换为干净 detached HEAD（3818dbb7），未绕过保护强制删除。其他分支、工作树及原始验收资源未清理。

[实施与未完成项记录](2026-10-29-p07-trace-publication.md)和历史失败/跳过证据保持原样；本报告补充其提交合并状态。设备、授权、独立目标参考/容差、P08 因果证据与远程 CI 的缺口均保留，不提高能力状态。

[合并后验证与清理证据](evidence/2026-10-29-p07-trace-publication-main-merge/)。
