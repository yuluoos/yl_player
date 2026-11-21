# OPPO Android 网络故障、直播与资源释放验收

2026-11-21 在 OPPO CPH2065（Android 12，API 31，arm64）上运行，播放器源码为 `87b9baa1`。所有媒体和故障均由受控测试端提供。每轮 Android 应用测试使用冷启动的 Debug APK，以设备安装包 SHA-256 和当前应用进程的 Flutter 终态核对结果。新增验收入口的源码哈希随各轮回执保留。[逐轮结果](evidence/2026-11-21-android-oppo-network-and-resource-regressions/results.json) · [原始采样与回执](evidence/2026-11-21-android-oppo-network-and-resource-regressions/captures.tar.xz)

## RTMP 故障

仓库现有的 6 个 RTMP 用例全部通过。H.264/AAC 和纯 H.264 均取得首帧并推进，停止后服务端关闭读连接。缺失候选源保留原会话，静默握手期间取消和替换均生效。设备在下行受阻时暂停 20 秒，恢复后原连接继续播放。连续三次断流后，设备均在同一会话取得新的公开画面；重试延迟为 500、1,000、2,000 ms。第四次断流返回 `network.rtmp_disconnected`。在等待重试时停止，也阻止了后续连接。[故障测试](../../../packages/yl_player/example/integration_test/rtmp_playback_test.dart) · [RTMP 本机测试服务](../../../tool/rtmp_acceptance/README.md)

首轮长播完成 600.407 秒观察，120 次采样持续推进，随后停止并进入 idle。设备读取代理统计时超过 5 秒，Flutter 上报超时。保留首轮失败回执。复测保持主机唤醒，同时从主机独立采集代理统计；设备可在 20 秒内重试只读状态查询。

复测以单条 RTMP 连接连续运行 600.420 秒。首帧后每 5 秒核对同一会话的播放位置，120 次采样持续推进，最终位置为 596.963 秒，公开重缓冲计数为 1。停止后设备进入 idle，服务端共接入并关闭一个读连接，活动读连接为 0。[长播测试](../../../packages/yl_player/example/integration_test/rtmp_sustained_playback_test.dart)

## 直播固定模式

每组独立加载后固定一种模式，观察 36 秒。三种协议均使用同一份 H.264/AAC 媒体和 `down-and-recover-v1` 限速配置。逐轮重放设备状态与转发服务记录，6 组均覆盖三个网络阶段并完成清理。下表列出每组一次运行中，从首帧后的首次采样到末次采样的重缓冲增量。[固定模式测试](../../../packages/yl_player/example/integration_test/live_mode_baseline_test.dart)

| 协议 | 流畅模式 | 低延迟模式 |
| --- | --- | --- |
| HLS | 1 次，共 1.577 秒 | 2 次，共 1.418 秒 |
| HTTP-FLV | 0 次，0 秒 | 0 次，0 秒 |
| RTMP | 0 次，0 秒 | 0 次，0 秒 |

每组有 143–144 个状态样本。缓存状态未控制；单轮数据适用于本机与本次网络曲线，尚无物理端到端延迟或可用于发布的时延分位数。

## 弱网重复测量

| 自动 DASH 场景 | 结果 |
| --- | --- |
| 40 秒素材，停供 25 秒 | 服务端三个阶段写出 1,110,058 / 0 / 1,248,800 字节媒体数据。连续采到 42 个 buffering 状态，播放位置在 18.9 秒附近。恢复供流约 0.706–0.759 秒后首次采到 playing，原会话播到 40 秒。 |
| 120 秒素材，停供 25 秒 | 三个阶段写出 977,737 / 0 / 6,096,477 字节。连续采到 48 个 buffering 状态，播放位置在 16.85 秒附近。恢复供流约 0.569–0.627 秒后首次采到 playing，原会话播到 120 秒。 |
| 120 秒素材，限速后恢复，两轮 | 两轮均降至 320×180 后回升到 640×360，播到片尾，公开重缓冲计数为 0。恢复后 0.632 秒和 0.701 秒分别首次请求高档分段；公开输出尺寸分别在恢复后 20.83–20.88 秒、20.65–20.72 秒回升。两轮记录到 333 和 334 个请求，失败数均为 0。 |

时间范围包含主机与设备时钟对齐误差。停供从首个 GET 后第 5 秒至第 30 秒，恢复时间取首次采到 playing 的时刻。两轮停供各产生一次重缓冲。限速用例使用同一配置与素材，各自冷启动并使用独立的本机服务器、运行标识和设备转发端口。[DASH 测试入口](../../../packages/yl_player/example/integration_test/abr_network_profile_test.dart) · [上轮 40 秒停供对照](2026-11-21-android-oppo-playback-regressions.md)

## 错误隔离

三项均通过。对返回 HTTP 403 的 DASH 清单，即使允许重试，设备也只请求一次，返回 `network.http_forbidden`。把重定向上限设为一次时，服务器收到最初和跳转后的两个请求，第三个请求被阻止，设备返回 `network.redirect_limit`。两种错误都没有发布会话。加载损坏的外部 SRT 时，字幕操作返回 `subtitle.malformed`，原视频会话继续推进超过一秒，保持 playing，无视频失败。[真机错误隔离测试](../../../packages/yl_player/example/integration_test/android_managed_fault_isolation_test.dart)

## 重叠会话与原生资源

双播放器使用自动缓冲时，每约 0.75 秒读取一次 `adb shell dumpsys media.resource_manager`，仅汇总当前应用 PID 的 `non-secure-codec/video-codec` 条目。两个会话均已取得首帧的观察窗中，4 次系统采样均记录到 1 个 `c2.mtk.avc.decoder`。重开第一路后仍观察到 1 个，全部停止后的 5 次采样均为 0。停止第一路后旧会话命令被拒绝，第二路仍可跳转并继续播放。

首轮为双播放器指定显式缓冲字节上限，Android 在首个加载时返回 `policy.unsupported`。复测先断言该拒绝，再以支持的自动缓冲策略验证双路释放。该计数覆盖应用占用的视频解码器；Media3 对外的缓冲字节字段在此路径不可用。[双播放器用例](../../../packages/yl_player/example/integration_test/android_overlapping_release_test.dart)

仓库原生 instrumentation 用例 3/3 通过。软件解码触发帧资源上限后返回资源耗尽并归还全部池字节；实际回退引擎只发出一次终态，销毁后池占用为 0。DASH 核心释放后台资源后恢复前台，保留选中音轨并跨时段推进。首次离线构建缺少测试依赖，随后用仓库声明的版本重新构建并核对真机已安装 APK 哈希。
