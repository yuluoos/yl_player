# macOS 本地 MP4 和 AV1/Opus 格式复验

使用 Apple M1（MacBookPro17,1，macOS 27.0.1 / 26A434）。[上一轮完整矩阵](2026-10-31-macos-format-matrix.md)在应用 `025bd345…` 上有三项未通过。本文将正式应用、仅供实验的 AV1 准入构建及持续负载分开。

签名后的 macOS example 验收制品 `908f48e6ca105e6827895c730a6094c239a58c0fcb064cd19f0801d3803dbd02` 跑齐 44 个场景，必测通过 **38/40**。本地 MP4 的声学输出通过。未通过的必测项为 MKV AV1/Opus 的文件和受管 HTTP，均返回 `decoder.unavailable`。两个 MPEG‑2 诊断和两个截断 MP4 对照单列。44 项均绑定同一制品，归档原始记录重放与现场逐行一致。[正式矩阵](evidence/2026-10-31-macos-format-followup/formal-matrix/matrix-result.json) · [本地 MP4](evidence/2026-10-31-macos-format-followup/formal-matrix/local-mp4.json)

## AV1 软件解码和颜色

1. 软件准入键原先对启动器进行散列。Xcode 分离构建将 Swift 解码器放在另一份 Mach-O 中。定向原生测试复现了两份哈希不同，修复后使用包含 Swift 解码器的实际加载映像和 codec 库生成身份。[原生红绿回执](evidence/2026-10-31-macos-format-followup/native-regressions.json)
2. 隔离实验仅为本机、该 OS、AV1 Main 8-bit 4:2:0、320×180、24 fps、2 线程及 420v 像素格式提供临时预算。使用真实 dav1d、播放器输出和资源监控。文件和受管 HTTP 都能完成公开播放和三次跳转，但绿色中心像素实测为 `(0,215,0)`，原有严格像素检查均失败。[实验修复前](evidence/2026-10-31-macos-format-followup/av1-trial-red-summary.json)
3. 固定素材没有声明原色、传递函数和矩阵。正常播放预期绿色为 `(0,255,0)`。软件输出对完全未标注的标清、8 位、有限范围 AV1 采用 BT.601 显示转换，保留显式标记、HDR 附件及 10 位输出。FFmpeg 的常量表也将其默认转换矩阵定义为 ITU601。修后两种传输均通过原有画面、PCM、三次 seek、完成和释放检查。该实验的临时预算独立于生产准入。[实验修复后](evidence/2026-10-31-macos-format-followup/av1-trial-fixed-summary.json) · [FFmpeg 转换矩阵定义](https://www.ffmpeg.org/doxygen/9.0/group__libsws.html)

## 持续资格试验

使用公开 Flutter 控制器、原生视图和优化后的 arm64 播放器。长素材复用固定 AV1 压缩图像包，并配用连续的立体声 Opus 测试音。合计 28,904 帧。先修复了阻止 Release 编译的两处 Debug 诊断属性转发。事先规定两次独立进程、同一优化制品、每次至少 20 分钟、热状态 nominal、关闭低电量模式、无掉帧及解码错误。程序在基线合格后按实测峰值和预先确定的余量冻结上限。[固定协议](evidence/2026-10-31-macos-format-followup/sustained-protocol.json)

原显示路径的首次基线在约 61 秒出现 `catchUp` 掉帧并终止。增加显示回调与队列记录后提前复现。媒体位置为 10.472166 秒，队列有 8 帧；距前次回调 66.447 毫秒，播放器跳过 PTS 10.417 秒的帧并选中 10.458 秒的帧。两次失败均保留。随后单独用项目已有的定时提交路径测量，读取了系统显示层的实际总帧、掉帧与损坏计数。[首次失败](evidence/2026-10-31-macos-format-followup/baseline-first-receipt.json) · [调度观测](evidence/2026-10-31-macos-format-followup/baseline-window-receipt.json)

## 本地 MP4 的声学观测

播放器继续走默认 AVPlayer 路径。用户授权的独立 macOS 助手使用内置麦克风，以 40 毫秒窗口记录八个固定测试音频带的归一化能量、采样序号和时间戳。根据信号中实际出现的相邻音调切换定位媒体时点；用同一次采集的样本序号计算其他窗口的位置，并与原生视图的中心像素配对。验证同时要求原有源端 PCM 窗口、三次 seek、首帧、完成、释放和制品身份全部合格。该方法给出固定素材的标记时间范围，未读取 AVPlayer 的逐样本硬件寄存器。

静音预检中，系统为内置扬声器、音量 0，麦克风未观测到连续的测试标记。临时解除静音并将扬声器设为 40% 后，检测到四种实际音调。正式采集时会先记录启动前的静音对照，seek 会延长至下一个音调边界。采集未保存麦克风 PCM，运行结束恢复系统音量及静音状态。接入步骤见[macOS 声学采集](../../../tool/media_matrix/BOUND_AV.md#built-in-microphone-observation-on-macos)。

## 双线程复验结果

20 分钟基线完整结束，解码 28,904 帧。应用和最终系统显示层均报告零掉帧、零损坏。最终显示层累计 28,903 帧。96 帧短片在原优化二进制上复现了 95 的最终层计数；分层诊断构建记录了 PTS 0 由原显示层取走，其余 95 帧提交给定时层，延迟查询仍为 95。两种显示层的帧数不能直接相加，原层可以多次发布同一首帧。长测未在原层保留逐帧回执。[短片交接记录](evidence/2026-10-31-macos-format-followup/short-renderer-handoff.log)

独立进程使用相同优化制品，按已冻结的 3,014,656 字节、27 帧、4,096 字节单包、每 1 秒 239 毫秒 CPU 和单次原生调用 58 毫秒墙钟上限运行。约 232 秒后返回 `resource.exhausted`。实测单次耗时 68.2395 毫秒，CPU 峰值 189.110 毫秒，已解码 5,591 帧。系统最后一次回读为 5,519 帧、零掉帧及损坏。该轮未达 20 分钟，**双线程档位未取得生产资格**。[原始峰值、预算和结论](evidence/2026-10-31-macos-format-followup/sustained-outcome.json)

后续诊断区分了原生调用时间与调用结束后取得账本锁的时间。正式代码现于 C 调用返回时截取墙钟，再在串行账本内采集 CPU、热状态和单调时钟。另一次诊断的慢 `send` 调用约 24.8 毫秒，锁等待约 9 微秒。该次诊断与其他宿主构建、测试有时间重叠，在队列超时处结束，没有重现原先的 68.24 毫秒。已准入的本地 dav1d VOD 在符合现有原生视图、可 seek 和缓冲条件时使用定时提交路径。

## 正式宿主与准入

用户指定仓库 macOS example。正式路径从应用签名覆盖的 `Contents/Resources/yl-player-qualified-av1.json` 读取精确配置。资源缺失、应用封印无效、解码器或规格不匹配均不会开放软件解码。独立复验失败，签发工具拒绝生成档位。[签发结果](evidence/2026-10-31-macos-format-followup/profile-issuance.txt)

在签名 example 验收应用的独立副本中，添加无效资源后严格签名校验失败；只重新签外层后校验通过，实际 Swift 解码器动态库与 codec framework 的 SHA-256 均与原包一致。该测试使用本地 ad-hoc 签名和 Xcode 分离映像布局，没有签发有效生产档位。[签名与映像对照](evidence/2026-10-31-macos-format-followup/formal-host-seal-control.json)

正式本地 MP4 第一次声学验收在白色标记时缺少足够强的音调，保留失败。临时将扬声器调至 55% 后，同一验收应用的 7 组标记全部通过，并恢复到音量 0、静音。真实结果同时要求公开框架成功、制品不变和原始观测重放。[不足的采集](evidence/2026-10-31-macos-format-followup/mp4-acoustic-insufficient-result.json) · [通过的采集](evidence/2026-10-31-macos-format-followup/mp4-acoustic-pass-result.json)

正式宿主定向 XCTest 5/5 通过，另有构建身份红绿回归和 8/10 位颜色回归。签发器的三项单测、声学正负例及采集回归通过。

[归档 SHA-256 清单](evidence/2026-10-31-macos-format-followup/sha256.json)，清单摘要 `082e045ddce7471bce0a6af806f4cdc07ebb9dad3ffd1d17254c3d8b2a85c3ee`。
