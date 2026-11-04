# macOS AV1 暂停背压修复与显示观测干预

本轮修复了显式暂停期间的帧队列超时丢帧。4 项定向 macOS 回归通过。持续显示故障尚未定位，没有签发 AV1 生产档位，也没有更新正式 AV1 矩阵为通过。

## 暂停期间的队列超时

沿用上一轮已经验证的退出取消顺序，进一步检查暂停路径。暂停原先只停止音频及媒体时钟，已经在满队列上等待的生产者仍按墙钟计算容量超时，导致用户暂停期间丢掉待提交帧。

新增回归使用真实 demux、decoder wrapper 和帧队列，容量设为 1，测试等待上限设为 100 毫秒；确认生产者已经等待后暂停 200 毫秒。修复前暂停阶段出现 1 次掉帧，恢复后计数继续增加；修复后暂停保留已排队及正在等待的帧，恢复并释放容量后按序继续提交，掉帧保持 0。

实现中，显式 pause 在原生音频控制之前通知队列暂停等待计时。队列以单调时间扣除暂停区间，恢复时继续使用剩余活动等待预算。容量允许时仍可入队；flush 的 generation 变化和 dispose 均能唤醒并取消等待。正常播放的默认 250 毫秒预算没有扩大，音频时钟过期不会被当成用户暂停而无限等待。

本轮 4/4 定向用例覆盖暂停/恢复、上一轮退出取消、正常容量超时分类，以及释放容量后的背压唤醒。模板同步检查通过：iOS 903、macOS 952。未执行完整原生套件或 iOS 宿主测试。初次回归源码错误地从 backend 包装器读取 session 私有属性，编译失败；改为使用受控解码会话实际收到的 generation 后才取得有效失败断言。编译失败不计作 RED。

- [有效失败断言](evidence/2026-11-03-macos-av1-pause-backpressure/pause-red-tests.json)
- [四项通过摘要](evidence/2026-11-03-macos-av1-pause-backpressure/pause-green-summary.json)
- [实现及回归 diff，包含上一轮退出修复](evidence/2026-11-03-macos-av1-pause-backpressure/changes.diff)

## 显示阶段的诊断结论

上一轮独立原生程序在约 63 秒报告系统掉帧。系统日志显示对应区间图像队列掉帧，而前一级解码/转换队列没有掉帧或晚输出。WindowServer 在相同的秒级窗口有一批日志延后，既没有调用来源，也没有精确丢失 PTS，不能据此认定其造成了掉帧。[上一轮证据](2026-11-03-macos-av1-queue-timeout.md)

新的独立原生诊断添加了固定长度的标量时序记录：CVDisplayLink 回调、主线程 10 毫秒心跳和提交入口/返回时刻。保持原有 24 fps、50 毫秒提交窗口和 10 毫秒供帧 timer。该轮完整 4,320 帧没有掉帧，最小提交提前量约 39.758 毫秒。未复现时没有输出失败环形记录，因此不能据此推断线程完全没有延迟。

为检查观测代码是否改变条件，随后在同一进程冻结三段各 180 秒：第一段同时启用刷新回调与心跳；第二段停用刷新回调；第三段再停用心跳。供帧和系统指标采集始终不变，计数不清零。最终 12,960 帧、0 掉帧、0 损坏，最小提前量约 38.225 毫秒。该结果不支持把保持刷新回调或心跳直接作为生产修复，也不能消除此前失败。两个程序均未包含 Flutter、实时 AV1 解码和音频，不是 AV1 的双轮长播资格。

- [三分钟诊断协议](evidence/2026-11-03-macos-av1-pause-backpressure/plan.json) · [原始记录](evidence/2026-11-03-macos-av1-pause-backpressure/raw.log)
- [九分钟干预协议](evidence/2026-11-03-macos-av1-pause-backpressure/intervention-plan.json) · [原始记录](evidence/2026-11-03-macos-av1-pause-backpressure/intervention.log)

## 后续边界

用户已明确选择保留现有原生呈现路径，继续系统级抓取；不切换 Metal。50 毫秒提前量、100 毫秒时钟有效期和零系统掉帧门槛不变。

另核对到资格捕获需要解决制品身份问题：此前隔离诊断直接修改 `YlSoftwareDecodeServices` 注入试验预算，修改了被测 Swift 映像。即便该副本通过，也不能把其档位套用于移除注入后重新构建的生产解码器。签发器本身要求精确映像匹配；后续长测前应使用能够保留最终解码器映像的受控注入入口，不能伪造基线/复验摘要来打开生产准入。本轮未修改签发器，也未生成临时“合格”资源。

## 系统级抓取遇到锁屏

使用 Animation Hitches 模板启动不含额外 CVDisplayLink/主线程心跳的原生程序，保留逐帧提交标量环形记录。工具能够导出渲染和刷新相关事件；这种重型采集的开销尚未隔离，不用作无探针性能或产品资格证据。[Apple 对渲染阶段卡顿工具的说明](https://developer.apple.com/videos/play/tech-talks/10857/)

约 35 秒，AppKit 可见性变为 false，系统会话锁定，`com.apple.loginwindow` 的两个窗口覆盖测试区域 100%。此前最后可见采样为 829 帧、零掉帧；最终为 853 帧、4 次掉帧。目标按失败退出。Instruments 导出在 trace 时间 36.106 秒和 36.406 秒分别记录 150 毫秒及 650 毫秒 hitch；这些发生在锁屏转换窗口，不能解释之前无遮挡对照的偶发掉帧。

原始采集临时增长到约 8.1 GB。目标退出后采集器仍在高 CPU 处理，发出 SIGINT 后完成保存，最终 trace 约 945 MB，CLI 退出码 54；目录及 hitch 导出成功。完整 trace 仅保留在 `/private/tmp/yl-av1-system-capture/display.trace`，仓库保存定向导出和原始计数。随后准备改用 System Trace 与 5 秒滚动保留窗口；用户确认现在可以保持解锁后，已执行下述抓取。

[锁屏采集摘要](evidence/2026-11-03-macos-av1-pause-backpressure/system-capture/summary.json) · [计数与提交时序](evidence/2026-11-03-macos-av1-pause-backpressure/system-capture/raw.log) · [系统 hitch 导出](evidence/2026-11-03-macos-av1-pause-backpressure/system-capture/hitches.xml) · [下一轮准备协议](evidence/2026-11-03-macos-av1-pause-backpressure/system-capture/next-plan.json)

签名控制也在隔离副本中完成：本次 Release 的实际 Swift 解码器映像位于主可执行文件。添加 `schemaVersion:0` 的无效资源并仅重签外层后，签名校验通过，但整个主映像哈希以及签名前缀哈希均改变，签名区从 12,336 字节变为 11,616 字节。该无效资源不构成准入记录。它证实当前静态链接布局不能直接沿用重签前的档位身份；这一包装问题还未修复。[前后身份](evidence/2026-11-03-macos-av1-pause-backpressure/system-capture/seal-after.json)

## 解锁后的五分钟 System Trace

用户确认可以保持桌面解锁后，以相同原生显示程序执行五分钟抓取。目标及采集器均以 0 退出；应用原点至最终计数约 302 秒，累计提交及系统呈现均为 7,200 帧，掉帧和损坏均为 0，最小提交提前量约 35.960 毫秒。全部周期可见性采样为 true；曝光事件没有记录锁屏或上层遮挡。这一轮没有复现上一轮锁屏，也没有复现之前无遮挡情况下的掉帧。

完整 trace 约 146 MiB，保留在 `/private/tmp/yl-av1-visible-system-trace/display.trace`。请求的滚动窗口为 5 秒，但导出的摘要和线程状态表实际仅覆盖约 10 秒。摘要日期与应用 302 秒日志不能直接对齐，因此不将其宣称为完整五分钟或已确认的末尾时序。导出的 17,087 个目标线程状态区间中，最长 Runnable 区间约 1.020 毫秒；长 Blocked/Idle 区间本身不能作为显示超时证据。这些局部数据不足以解释历史掉帧，且本轮未触发失败提交环形记录。

本轮沿用预解码 NV12 原生显示对照，不含 Flutter、实时 AV1 解码或音频；没有新增生产修复，也没有重复运行已通过的暂停回归。AV1 的持续显示故障定位及最终制品身份问题仍未完成，正式资格状态保持失败/未签发。

[抓取摘要](evidence/2026-11-03-macos-av1-pause-backpressure/visible-system-trace/summary.json) · [全程应用计数](evidence/2026-11-03-macos-av1-pause-backpressure/visible-system-trace/raw.log) · [trace 目录](evidence/2026-11-03-macos-av1-pause-backpressure/visible-system-trace/toc.xml) · [压缩线程状态导出](evidence/2026-11-03-macos-av1-pause-backpressure/visible-system-trace/thread-state.xml.gz)

[归档 SHA-256 清单](evidence/2026-11-03-macos-av1-pause-backpressure/sha256.json)。
