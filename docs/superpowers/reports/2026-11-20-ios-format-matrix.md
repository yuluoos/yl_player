# iPhone 16 格式验收，2026-11-20

**iOS 格式必测项全部通过，含补验共 40/40 项。本地文件 20/20，受管 HTTP 20/20。** 首轮完整运行通过 39 项。按本地 MP4 播放功能验收口径复核，同一构建随后两次通过了唯一剩余的本地 H.264/AAC MP4，候选构建也在三次冷启动中通过了该项。每项按格式和输入方式只计一次。[首轮矩阵](evidence/2026-11-20-ios-format-matrix/matrix-result.json) · [补验记录](evidence/2026-11-20-ios-format-matrix/mp4-startup-attempts.json.xz)

## 首轮完整运行（补验前）

主线提交 `34878df50b9e368d99c54cff1fff3ac52241ba65` 在 iPhone 16（iOS 27.2，24B119）上完成全部 44 项。40 项必测通过 39 项，本地 H.264/AAC MP4 在这次运行中超时。相同 MP4 的受管 HTTP 播放通过。[逐项结果](evidence/2026-11-20-ios-format-matrix/matrix-result.json)

| 输入 | 必测通过 | MPEG-2 诊断 | 截断 MP4 |
| --- | --- | --- | --- |
| 本地文件 | 19/20 | `decoder.unsupported` | `avplayer.-11829` |
| 受管 HTTP | 20/20 | `decoder.unsupported` | `container.mp4_open_failed` |

## 本地 MP4 的两次真机观测

两次均从公开播放器收到 ready、播放命令回执和首帧。初始播放阶段等待原生音频时钟达到目标，在 12 秒超时。两次均采到 0 个 PCM 块，未进入后续 seek 验证。首次未完成快照显示 AVPlayer 暂停、位置 0、无条目错误码。复核快照显示位置仍为 0，会话已失败，AVPlayer 的错误链数值为 `-11800`、`-66681`。本机 iOS SDK 的 AudioQueue.h 将后一个数值定义为 `kAudioQueueErr_CannotStart`。触发音频队列启动失败的原因仍待定位。[首次快照](evidence/2026-11-20-ios-format-matrix/mp4-first-unfinished.json) · [复核快照](evidence/2026-11-20-ios-format-matrix/mp4-recheck-unfinished.json) · [复核结果](evidence/2026-11-20-ios-format-matrix/mp4-recheck-result.json)

11 月 5 日的旧构建在此项已完成取样，当时的严格验收还要求实际播放时钟证明。此次完整矩阵在更早的音频采样阶段就停止。[历史记录](2026-11-05-remaining-device-acceptance.md)

## 构建与回放核对

使用 Xcode 27.2（27B52），从 `integration_test/bound_av_test.dart` 构建已签名的 Debug 应用，Swift 显式开启 `YL_BOUND_AV`。矩阵 ID 为 `feb85b8e-a3fd-4609-abb8-eb459e017c92`，冻结应用文件清单的 SHA-256 为 `e3c823ba1e4e3c0880a77ceadf68f666fb60f5665f429082edd4a976d32fe238`。44 项串行执行，每项均取回停止回执，最终应用文件核验一致。随后仅用同一应用复核本地 MP4，单独保留了两次失败。仓库的 `bound_matrix.summarize` 重放原始数据所得结果与矩阵结果文件逐项相同。[执行计划](evidence/2026-11-20-ios-format-matrix/matrix-plan.json) · [应用文件清单](evidence/2026-11-20-ios-format-matrix/product-files.json) · [可重放的原始数据](evidence/2026-11-20-ios-format-matrix/records.json.xz)

## 本地 MP4 启动策略补验

iOS AVPlayer 对本地文件使用自动缓冲时，现在通过设置目标速率启动，使系统可以等到准备就绪再播放。原实现虽然开启了自动等待，启动时仍调用 `playImmediately(atRate:)`。低延迟模式继续立即启动。验收采样循环遇到公开会话的终止错误时，直接抛出该错误，保留错误码。[实测代码差异](evidence/2026-11-20-ios-format-matrix/mp4-startup-tested.patch)

在同一台 iPhone 上，原构建追加的两次本地 MP4 对照均完成播放，此前两次超时保留。另一个只更改 tap 安装时机的实验仍在 12 秒超时，已撤回。最终候选的三次冷启动全部完成播放、三次 seek、PCM 与画面取样和资源释放，均通过 `renderPullAcceptance`。同一候选的受管 HTTP 用例通过严格验收。原构建也能成功，因此这些运行尚不足以确定历史故障的唯一根因或估计发生率。本地 MP4 播放功能验收无需麦克风或硬件播放时钟证明。三次本地运行仍报告 `played_sample_clock_unverified`。候选只做了定向补验，没有与旧构建的其他用例合并计数。[逐次结果](evidence/2026-11-20-ios-format-matrix/mp4-startup-results.json) · [原始记录](evidence/2026-11-20-ios-format-matrix/mp4-startup-attempts.json.xz)

iPhone 原生 AVPlayer 缓冲和恢复套件 24/24 通过，其中检查了自动缓冲与低延迟对本地 MP4 的启动方式和 1.25 倍速传递。Flutter 采样回归 8/8 通过。首次原生套件启动因测试包缺签名未加载用例，启用现有开发签名后完成验证。[真机 XCTest 摘要](evidence/2026-11-20-ios-format-matrix/mp4-startup-native-summary.json)
