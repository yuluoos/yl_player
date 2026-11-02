# macOS AV1 公共视图投影修复与 Metal 试验

已修复 `YlPlayerView` 在播放进度通知时重复构造原生视图子树的问题。单线程 AV1 的完整双轮资格验收仍未通过。实验使用 MacBookPro17,1、26A434、arm64 Release、320×180、24 fps、单线程 dav1d 和原有 28,904 帧长素材。[此前实验和冻结预算](2026-11-01-macos-av1-single-thread.md)

## 公共视图修复

用户选择试验另一条原生呈现路径后，在隔离副本实现了 `CAMetalLayer`、Core Image 转换和按主机时间提交的端点。逐帧保留 PTS、目标主机时间和 `MTLDrawable.presentedTime`。实际呈现时间为 0 的 drawable 计为丢失，晚于目标一帧以上的情况另计。Apple 将 `presentedTime` 为 0 定义为尚未呈现或相应帧被丢弃。[Apple 接口说明](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)

同一进程前 45 秒暂停公共视图对控制器状态的订阅，零 drawable 丢失。恢复正常订阅后的 5 秒内出现 15 个丢失和 1 个超过一帧的延迟，最大延迟约 68.4 毫秒。窗口遮挡计数为 0。布局记录只有启动时的一次布局，不能将这次结果解释为重复尺寸变化。[同进程 A/B 原始记录](evidence/2026-11-02-macos-av1-display/metal-spike/metal-state-ab/baseline/raw.log)

生产代码增加视图专用投影，缓存画面相关状态对应的子树。投影包含控制器和会话身份、几何、原生及受保护表面、首帧状态、字幕及视图配置。仅进度或指标变化时复用子树。纹理身份仍保留独立监听，父级配置和控制器替换会更新投影。[实现](../../../packages/yl_player/lib/src/player_view.dart)

新增回归在修复前复现原生 `AppKitView` 对象随进度通知重建，修复后通过，并验证几何变化仍更新视图。播放器视图 27 项测试、字幕运行时及受保护字幕 38 项测试通过，两个改动文件的定向静态分析通过。一次只读定向代码复审没有发现可操作的正确性问题，没有重跑测试。[回归用例](../../../packages/yl_player/test/player_view_test.dart)

## Metal 试验边界与结果

独立 Metal 原型最初在窗口可见后立即计时，前 7 个 drawable 回执为 0。随后增加实际呈现回执作为准备条件。一次原生短测与 Release 构建重叠，其丢失和延迟记录保留，不作为独立稳定性结论。

暂停视图订阅的播放器实验在约 220 秒前零丢失，随后出现一次窗口遮挡和 1 个 drawable 丢失。应用正式投影修复、保留正常订阅后，5 秒采样仍报告启动期 1 个丢失和 5 个超一帧延迟，最大延迟约 86.4 毫秒。投影修复没有证明能消除全部 Metal 呈现问题。[暂停订阅实验](evidence/2026-11-02-macos-av1-display/metal-spike/metal-stable-view/baseline/receipt.json) · [正常投影实验](evidence/2026-11-02-macos-av1-display/metal-spike/metal-projected-view/baseline/receipt.json)

Metal 仅实现固定 8 位 SDR 连续播放试验，GPU 分配未接入资源账本，暂停、跳转和重新挂载未完成生产验收。回读中的 `corruptedFrames` 是兼容占位值 0，`totalFrameDelaySeconds` 暂存最大延迟；实际评估使用独立的 `maximumPresentationDelaySeconds` 和原始逐帧回执。这些字段不能作为 AVFoundation 系统计数使用。试验代码保存在证据目录，生产端点没有切换到 Metal。[试验端点源码](evidence/2026-11-02-macos-av1-display/metal-spike/source/YlMacosTimedVideoEndpoint.swift)

## 现有原生显示路径复验

应用公共视图修复后，使用原来的 50 毫秒提前量和三帧在途限制，等待公开首帧里程碑及 Flutter 帧结束，再检查原生视图并调用播放。基线于 589.225 秒因播放器 `enqueueTimeout` 停止。此前最后一次系统采样累计 14,040 帧，系统掉帧、损坏及窗口遮挡均为 0。由于完整播放未结束，这轮不合格，也没有由此冻结预算或启动独立复验。系统日志在最后一次采样之后也出现了额外显示队列丢帧，最后一次采样不能代表整个失败窗口。[运行回执](evidence/2026-11-02-macos-av1-display/projected-native-qualification/baseline/receipt.json) · [系统日志](evidence/2026-11-02-macos-av1-display/projected-native-qualification/baseline/system.log)

随后仅在失败时增加时钟、工作线程和排队 PTS 输出。该轮约 145 秒先因遮挡计数变成 1 被判失败，清理期间才出现 `enqueueTimeout`，此超时不作为独立根因证据。失败后观测到音频时钟读取峰值约 226 毫秒，但采集发生在清理阶段，尚不能据此判断此前超时由音频读取造成。[诊断原始记录](evidence/2026-11-02-macos-av1-display/projected-timeout-diagnostic/baseline/raw.log)

剩余工作是取得首次队列超时之前的有效时序证据并修复实际停顿，随后完成同一构建的 20 分钟基线和独立复验。日常使用期间已多次出现短时窗口遮挡，严格的零遮挡验收需要连续可见的运行时段。此前所有失败均保留，生产资格尚未取得。[完整 SHA-256 清单](evidence/2026-11-02-macos-av1-display/sha256.json)
