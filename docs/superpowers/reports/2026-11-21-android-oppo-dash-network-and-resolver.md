# OPPO Android DASH、网络错误与脚本播放验收

2026-11-21 在 OPPO CPH2065（Android 12，API 31，arm64）上运行。播放器基于 `bf46950b`，本轮改动限于验收用例、报告和清单。每组核对构建与已安装 APK 的 SHA-256，Flutter 用例按应用进程终态计数，原生用例按 AndroidJUnitRunner 回执计数。下列数量不含框架收尾、重复运行或前一轮已验收的用例。[逐组结果](evidence/2026-11-21-android-oppo-dash-network-and-resolver/results.json) · [采样、失败首轮与设备回执](evidence/2026-11-21-android-oppo-dash-network-and-resolver/captures.tar.xz)

## DASH 与字幕

| 真机用例 | 通过 | 验证内容 |
| --- | ---: | --- |
| 候选源重试 | 3/3 | 一个候选失败后切换、全部候选失败、零重试预算。 |
| SegmentBase | 2/2 | 同一 AVC/AAC 素材的 sidx v0、v1 均可播放。 |
| DASH 加载与请求 | 6/6 | 无扩展名入口、自动识别、同源与跨源凭据策略、分段 403 和停止后抑制旧事件。 |
| 延迟重配置时取消或替换 | 2/2 | 两条路径均拒绝旧会话的迟到输出。 |
| 多 Period 与时间轴 | 19/19 | 覆盖固定 AVC 跨段失效后改选 HEVC，以及 18 个偏移、裁剪、空隙、重叠、编解码器、分辨率或轨道变化等场景。 |
| 视频空隙中的字幕 | 3/3 | 在 250、1,500、2,500 ms 的前、中、后空隙读取应用合成图像，三处背景 RGB 均为 [0, 0, 0]，各有 319 个白色字形像素；取消选轨后字幕消失。 |

分段 403 的首轮断言仍使用旧提示文本。设备返回 `network.http_forbidden`，公开提示带有实现定义的 `HTTP 403` 前缀。更新精确文本后整组复测 6/6，保留了凭据、地址脱敏和实际分段请求断言。[403 测试](../../../packages/yl_player/example/integration_test/android_dash_playback_test.dart) · [字幕图像测试](../../../packages/yl_player/example/integration_test/dash_video_gap_subtitle_test.dart)

## 音频、前后台与原生音画

渐进式播放、跳转与重新加载通过。纯音频播放进入后台后暂停，位置在 700 ms 内保持不变；返回前台后恢复播放，位置继续推进，全程无视频首帧。设备侧按测试标记实际执行 Home 和回到 Activity 两个动作。[真机生命周期测试](../../../packages/yl_player/example/integration_test/android_progressive_playback_test.dart)

原生 PCM 的 8 项用例全部通过，覆盖裁剪、偏移、跨段、重叠、前中后静音和跳转后的有效音频样本。3.5 秒裁剪交付 168,000 帧，7 秒重叠交付 336,000 帧；各轮消费结束位置距预期时长最多 10 ms。数据来自解码后的 PCM 与原生消费时钟。[原生 PCM 测试](../../../packages/yl_player_android/android/src/androidTest/kotlin/dev/ylplayer/yl_player_android/YlDashPcmInstrumentedTest.kt)

逐帧音画配对未完成。联合测量读取 ImageReader 像素平面时，测试进程内的 Android 图像读取接口触发 SIGABRT，AndroidJUnitRunner 报告测试进程崩溃；首组没有产生可配对样本。设备回执与脱敏堆栈均已归档。该用例需换用与此设备兼容且能保留帧时间戳的采样方式，或在支持该读取路径的设备上复测。[帧与消费时钟配对测试](../../../packages/yl_player_android/android/src/androidTest/kotlin/dev/ylplayer/yl_player_android/YlDashJointInstrumentedTest.kt)

## 脚本解析与播放

通用脚本运行时回归 9/9，覆盖公开结果与参数、无效返回值、未知宿主 API、超时后复用、取消和实际请求连接关闭、内存预算耗尽后复用，以及 HTTP MP4 交给播放器。HTTP MP4 的公开首帧匹配当前会话，停止后无迟到首帧。独立 RTMP 交接 1/1，受控脚本给出直播地址，播放器取得匹配会话的首帧与音轨；代理接入一次、关闭一次、清理后活动连接为零。[运行时用例](../../../packages/yl_player_source_resolver/example/integration_test/script_runtime_test.dart) · [RTMP 交接用例](../../../packages/yl_player_source_resolver/example/integration_test/rtmp_handoff_test.dart)

九份指定脚本的归档校验返回 `archive_unavailable`，JS-01 至 JS-09 本轮均未执行。恢复匹配冻结哈希的脚本归档后，才能逐份核对媒体交接与清理。

## DNS 与 RTMP 建连故障

RTMP 测试端收到客户端版本字节 3 后立即关闭，设备返回 `network.rtmp_handshake_failed`，保留诊断 ID，公开错误隐藏地址与私有路径，未发布会话。此前的播放中断用例已独立验证 `network.rtmp_disconnected`。[建连故障用例](../../../packages/yl_player/example/integration_test/android_network_start_failure_test.dart) · [上轮中断与恢复记录](2026-11-21-android-oppo-network-and-resource-regressions.md)

DASH 的系统 DNS 探测首轮使用 HTTP，调试应用只允许回环明文流量，清单和分段均得到 `network.failed`。改为 HTTPS 后，两处均得到 `network.tls_failed`。设备独立查证保留的测试域名返回了地址，未满足 DNS 失败前提。最终 Flutter 用例可通过 `YL_ANDROID_UNRESOLVABLE_HOST` 指定测试域名，发出媒体请求前先验证系统查询确实失败。本轮最终默认入口只运行握手用例。

原生受控 DNS 用例 2/2 通过。仅在测试传输层令指定域名的查询抛出 `UnknownHostException`，保留实际 DASH 播放器、托管 HTTP 客户端与公开错误映射。一项在清单请求失败；另一项先从回环服务取得清单，再在媒体分段资源请求失败。两者均映射到 `network.dns_failed`，公开提示未包含域名。真实系统 DNS 的两项端到端复测仍需要能返回负响应的网络环境。[原生 DNS 测试](../../../packages/yl_player_android/android/src/androidTest/kotlin/dev/ylplayer/yl_player_android/YlDashDnsInstrumentedTest.kt)

## 直播固定模式第二轮

RTMP、HTTP-FLV、HLS 各以低延迟和流畅模式单独冷启动，每组从首帧起固定模式观察 36 秒。使用与第一轮相同的仓库媒体和 `down-and-recover-v1` 网络曲线。逐组从应用样本和转发器连接记录重算结果。表内为窗口内重缓冲增量。[第一轮对照](2026-11-21-android-oppo-network-and-resource-regressions.md) · [固定模式验收](../../../packages/yl_player/example/integration_test/live_mode_baseline_test.dart)

| 协议 | 模式 | 第一轮（次数 / 总秒数） | 第二轮（次数 / 总秒数） | 第二轮样本数 |
| --- | --- | ---: | ---: | ---: |
| HLS | 低延迟 | 2 / 1.418 | 2 / 0.771 | 144 |
| HLS | 流畅 | 1 / 1.577 | 1 / 1.586 | 144 |
| HTTP-FLV | 低延迟 | 0 / 0.000 | 0 / 0.000 | 144 |
| HTTP-FLV | 流畅 | 0 / 0.000 | 0 / 0.000 | 144 |
| RTMP | 低延迟 | 0 / 0.000 | 0 / 0.000 | 144 |
| RTMP | 流畅 | 0 / 0.000 | 0 / 0.000 | 144 |

两轮均为本机短窗实测。尚无采集端与显示端共用时钟的端到端延迟、冻结性能目标或跨设备分位数。本轮不增加格式矩阵行；Android 仍为 38/40，AV1 本地文件和 HTTP 的正向硬解验收需要另一台支持 AV1 硬解的设备。

结果 JSON 的 SHA-256 为 `dff168714d469aa2c62ea23ba334fadea1935f6026560f9d26d95faa7a9188dd`，采样归档为 `bc0bc1462f837e04c071e0369e4dd7ec95b5f1199b9292bad045e5871753f76c`。归档内各文件的哈希列在结果 JSON 中。
