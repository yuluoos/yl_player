# iOS 点播画面冻结：现场诊断

报告的现象是同一视频持续播放、切集后均偶发画面冻结，音频先继续，随后播放停住，部分情况下 seek 可恢复。没有原始播放 URL 或现场错误，因此目前不能确认实际片源格式、选用引擎及根因。

## 本次范围

AVPlayer 原有超时检测覆盖首帧等待和 `timeControlStatus` 不再为 `playing` 的卡顿。首次出画之后，播放状态仍为 `playing` 但纹理没有新视频帧时，原有检测不会提供这方面的证据。

新增诊断独立观察视频帧发布和媒体进度，不触发 seek、重连、暂停或失败。超过 `max(readTimeoutMs, 5000)` 毫秒没有新画面时记录一次，并以同样间隔限频；恢复出画时记录一次恢复事件。暂停、seek、切集、停播和后台停用会重置观察区间。

## 复现后取日志

使用包含本次改动的应用，在连接 Xcode 调试控制台的 iPhone 上正常播放。出现问题后搜索 `[YLPlayer][AVPlayer]`，保留卡住前后及手动 seek 后的相关行即可，不需要提供播放 URL。

- `event=videoOutputGap`：长时间没有发布新视频帧。它本身不证明解码器故障，缓冲及低帧率内容也可能产生间隔。
- `frameGapMs`：距上次发布新视频帧的时间。
- `timelineGapMs`：距最近观察到媒体进度前进的时间。接近零意味着进度仍在推进；它不是音频硬件输出的直接测量。
- `positionMs`：当前媒体位置。
- `event=videoOutputResumed`：检测到长间隔后重新发布视频帧。

日志还记录 AVPlayer 状态、缓冲状态及 item 代次，用于区分同一视频和切集。日志不包含源 URL、请求头、凭据或任意系统错误描述。若没有这个前缀，仍需确认应用使用的是此版本，以及实际播放是否经过 AVPlayer 路径。

`event=playbackFailure` 记录原生错误及最多 8 层 underlying error 的数字代码，`event=stallTimeout` 记录原有超时检测触发时的状态。`timeControl` 的 0/1/2 分别表示暂停、等待播放、正在播放；`itemStatus` 的 0/1/2 分别表示未知、就绪、失败。`loadedEndMs` 是最后一个已加载区间的终点，不代表当前位置之后一定连续有缓冲。

## 验证边界

可控时间戳测试能够验证诊断在无新画面、进度继续或停住时的行为，但不能复现或证明“波波秒播”的实际故障已修复。最终根因仍需要一次真实复现的诊断记录。

本地验证记录：

- 用实际 probe 源码及新增 XCTest 方法构建独立 macOS 测试程序：空实现时 3 项预期失败，实现后 4 项通过。覆盖进度继续/停住、限频、恢复、重置和无效位置。
- iOS `xcodebuild build-for-testing` 成功，包含实际 AVPlayer 后端接入代码。现有 Sendable 和 XCTest 最低系统版本链接警告仍存在。
- iOS 原生运行尝试停在模拟器测试启动阶段，已取消；没有将该尝试算作原生测试通过。
- 当前 fixture/example 一致性及测试清单通过（iOS 427、macOS 349）；这些数字是清单数量，不是本次执行的测试数量。
- 构建日志：`/private/tmp/yl-vod-diagnostics-build.log`；独立测试程序：`/private/tmp/yl-vod-probe/tests`。
