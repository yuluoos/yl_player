# macOS M1 单线程 AV1 资格试验

2026-11-01，单线程基线未通过。公开 Flutter 播放器在本地签名的 arm64 Release example 中播放文件。机型为 MacBookPro17,1，系统构建为 26A434。试验使用隔离副本，原生解码器创建时记录的线程数为 1。试验素材为 320×180、24 fps、8 位 AV1 Main 和立体声 Opus，含 28,904 个视频包。原计划要求基线连续播放至少 20 分钟、零掉帧，合格后才冻结资源上限并启动独立复验。[预设协议](evidence/2026-11-01-macos-av1-single-thread/protocol.json)

首帧 PTS 0 由原显示层取走，该层记录 1 帧、0 掉帧。应用在约 2 秒和 4 秒时均报告软件解码、0 掉帧。约 5 秒首次回读定时显示层时，系统报告总帧数 120、掉帧 33、损坏 0，触发停止。之后才出现一次 `enqueueTimeout`。解码器共输出 130 帧。采集到的原生调用耗时峰值为 1.320125 毫秒，每秒进程 CPU 耗时峰值为 203.292 毫秒。该短窗口无法定位显示层掉帧的根因，也不能用于推导持续运行的资源上限。[原始事件](evidence/2026-11-01-macos-av1-single-thread/baseline.log) · [制品哈希和运行回执](evidence/2026-11-01-macos-av1-single-thread/baseline-receipt.json)

基线失败后没有冻结预算、启动独立复验或签发生产档位。正式矩阵沿用上一轮同一签名构建的 38/40，AV1/Opus 本地文件与受管 HTTP 两项仍未通过。[正式矩阵与双线程试验](2026-10-31-macos-format-followup.md)

## 11 月 2 日显示队列定位

继续使用单线程、同一长素材和公开 Flutter 控制器。窗口完全遮挡会伴随系统掉帧，5 秒采样可能遗漏短时遮挡。验收宿主增加了从启动前开始累计的 AppKit 遮挡计数。实验窗口使用层级 28，位于已观测到的 Dock 层级 20 和悬浮窗口层级 27 之上。该设置只在显式启用的验收模式下生效。即便提高层级，仍保留了发生遮挡的失败记录。[遮挡记录](evidence/2026-11-02-macos-av1-display/visibility-trace/baseline/raw.log)

独立原生对照使用相同固定画面和 24 fps，排除 Flutter、实时解码和音频时钟。对照在窗口可见、首帧预提交后启动媒体时钟，完成 1,440 帧，系统掉帧和损坏均为 0。这只是 60 秒对照。[原生源码](evidence/2026-11-02-macos-av1-display/ExposurePreflight.swift) · [原生记录](evidence/2026-11-02-macos-av1-display/native-preflight.log)

在用户确认保持桌面稳定后，50 毫秒提前量的播放器基线运行约 175 秒，系统在累计 4,200 帧时报告 1 帧掉帧，遮挡计数为 0。逐帧提交没有 PTS 跳号，最小提前量为 36.708 毫秒。另一次短诊断在持续播放阶段没有时间基准重设，系统媒体日志仍报告显示图像队列丢帧和过期移除，解码队列的丢帧及晚输出为 0。现有证据将问题收窄到系统显示队列，尚不能确定其触发根因。[稳定桌面失败回执](evidence/2026-11-02-macos-av1-display/stable-qualification/baseline/receipt.json) · [时间基准与系统队列日志](evidence/2026-11-02-macos-av1-display/anchor-trace/coremedia.log)

隔离实验将提前量调整为 100 毫秒，继续保留三帧在途限制。该实验基线完成 1,206.135 秒，解码 28,904 帧，最终定时层 28,903 帧，系统掉帧、损坏和遮挡均为 0。原层取走 PTS 0 的记录保留在同一进程日志中。按原规则冻结上限为 3,080,192 字节、28 帧、4,096 字节单包、每秒 245 毫秒 CPU 和单次原生调用 3 毫秒墙钟。[完整基线](evidence/2026-11-02-macos-av1-display/lead-qualification/baseline/receipt.json) · [冻结上限](evidence/2026-11-02-macos-av1-display/lead-qualification/baseline/limits.json)

同一签名构建的首次独立复验运行约 620 秒，在累计 14,880 帧时系统报告 1 帧掉帧，遮挡计数仍为 0，最后 5 秒内最小提交提前量为 89.663 毫秒。实测资源峰值均在冻结上限内。系统媒体日志记录显示图像队列 1 帧过期移除，解码队列没有丢帧或晚输出。该次独立复验未通过，100 毫秒实验没有取得资格，仓库的正式提前量仍为 50 毫秒。[首次独立复验](evidence/2026-11-02-macos-av1-display/lead-qualification/verification/receipt.json) · [失败窗口系统日志](evidence/2026-11-02-macos-av1-display/lead-qualification/verification/coremedia.log)

用户报告在约 00:15:28 失败时间附近使用过 AltServer，之后要求在继续日常使用电脑的条件下复验。这是外部活动的时间关联，尚无证据证明它造成了掉帧。原失败记录保留，后续复验继续使用同一实验制品及冻结上限。

日常使用条件下的重跑于 163.315 秒停止，返回 `resource.exhausted`。最后一次系统采样累计 3,841 帧，掉帧、损坏和遮挡均为 0。原生解码累计 3,896 帧，单次调用峰值为 8.392125 毫秒，超过冻结的 3 毫秒墙钟上限。CPU 峰值为每秒 223.1 毫秒，其他资源也在上限内。这次失败来自调用墙钟预算，不能与上一轮显示队列丢帧归为同一原因。[日常使用复验回执](evidence/2026-11-02-macos-av1-display/lead-reverification/verification/receipt.json)

额外隔离对照在 Swift 接收软件解码帧时，将当前固定 8 位素材复制到 IOSurface 像素缓冲，再交给相同定时显示层。该诊断保留 100 毫秒提前量，额外复制内存没有接入资源账本，结果仅用于显示定位。系统累计 1,441 帧时出现 1 帧掉帧，遮挡和损坏均为 0，诊断失败。IOSurface 副本没有进入仓库生产实现。[诊断回执](evidence/2026-11-02-macos-av1-display/surface-long-diagnostic/baseline/receipt.json) · [诊断源码](evidence/2026-11-02-macos-av1-display/surface-long-diagnostic/YlSoftwareVideoDecoder.swift)

本轮尚未修复单线程 AV1 偶发显示丢帧，也未签发生产档位。100 毫秒提前量和 IOSurface 复制均保留为实验记录，正式代码继续使用 50 毫秒提前量。已通过的三项启动及生命周期定向 XCTest 沿用上一轮有效结果，本轮未重复运行。Release 实验构建通过，最终增量文件检查通过。完整证据见 [SHA-256 清单](evidence/2026-11-02-macos-av1-display/sha256.json)。

后续 Metal 试验定位并修复了公共视图随进度通知重复构造原生子树的问题。65 项相关 Dart 测试通过，现有原生显示路径长测仍因队列超时中断，完整双轮资格验收尚未完成。[后续修复与试验结果](2026-11-02-macos-av1-view-projection.md)
