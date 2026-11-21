# OPPO Android 播放回归

2026-11-21 在 OPPO CPH2065（Android 12，API 31）上运行，播放器源码为 `b61cb6688165e276c47ddaa3ebb9e899fae3fb84`。使用仓库中的 Flutter 集成测试和自有媒体，按测试入口离线构建 arm64 Debug APK，安装后逐轮核对 SHA-256。框架终态取自本轮应用进程。[逐轮结果及哈希](evidence/2026-11-21-android-oppo-playback-regressions/results.json) · [原始采样、网络记录和运行回执](evidence/2026-11-21-android-oppo-playback-regressions/captures.tar.xz)

## 点播与会话

| 场景 | 用例数 | 真机结果 |
| --- | ---: | --- |
| DASH 缓冲耗尽后恢复 | 1 | 40 秒素材从网络时钟第 5 秒起断流 25 秒，期间媒体正文写入 0 字节。播放停在 18.444 秒，连续 44 次采到 `buffering`。供流恢复后约 0.68–0.74 秒首次采到 `playing`，原会话自行播到片尾，公开重缓冲计数为 1。时间范围包含设备与服务时钟对齐误差。 |
| 会话替换与双播放器回滚 | 4 | 新加载取消旧检查，旧会话命令被拒绝；切换前候选画面保持私有；延迟确认时原生回调顺序符合预期。第二个播放器加载 404 后，第一个播放器恢复播放。 |
| DASH 跨时段固定画质 | 1 | 无法满足的分辨率约束被拒绝后保留固定选择。第二个时段仍以固定 640×360 播放，第 8 秒进入缺少高档的时段后以 `trackUnavailable` 回退自动 320×180，并在并发限高、跳回第 1 秒后保持 320×180。收集到 96 个状态样本和 99 个请求。 |
| 音轨与字幕 | 6 | 两项音轨测试覆盖同语言音轨重排、跳转、限高后保持选择，以及下一时段缺轨时返回 `track.not_found`。WebVTT、TTML、WVTT、STPP 各一项，在 0.5、2.5、4.5、5.5 和 7.5 秒检查合成画面，共 20 个采样点，包含无字幕间隙；另检查关闭字幕后的画面。 |

断流样本采用约 250 ms 采样间隔。供流恢复时间以服务端首个 GET 为基准，恢复等待时间取恢复后的首个播放状态采样。跨时段素材由仓库工具以 `--missing-high-after 2` 生成。[断流测试入口](../../../packages/yl_player/example/integration_test/abr_network_profile_test.dart) · [跨时段测试入口](../../../packages/yl_player/example/integration_test/abr_fixed_period_test.dart)

## 直播模式切换

三种协议均使用同一份 H.264/AAC 素材，经 USB 回环转发，在 `down-and-recover-v1` 配置下运行。第 10 秒限速，第 25 秒恢复。测试在暂停时切到低延迟，恢复播放后切回流畅，再检查连续切换、替换和停止后的过期命令。表中耗时从发出切换命令到观察到对应公开状态，仅代表本轮测量。[直播测试入口](../../../packages/yl_player/example/integration_test/live_mode_switch_test.dart) · [网络配置](../../../tool/playback_network/profiles.json)

| 协议 | 切到低延迟 | 切回流畅 | 快速切换与旧命令检查 |
| --- | ---: | ---: | --- |
| HLS | 33.52 ms | 44.14 ms | 通过 |
| HTTP-FLV | 40.77 ms | 16.58 ms | 通过 |
| RTMP | 33.34 ms | 26.74 ms | 通过 |

三种协议各有一次完整的真机运行，网络三个阶段均有下行数据。RTMP 首次准备环境时，脚本未识别 MediaMTX v1.21.1 的监听日志，尚未启动设备测试。修正就绪判断后，使用相同媒体与限速配置完成整轮。三轮均通过仓库直播汇总器重放，结束后设备的 USB 转发列表为空。

本轮合计通过 15 个功能用例。直播端到端延迟、真实扬声器输出及最低支持版本 API 24 的表现仍待独立测量。Android 格式矩阵仍为 38/40；AV1 本地文件和 HTTP 硬解正向验收需要支持 AV1 硬解的设备。
