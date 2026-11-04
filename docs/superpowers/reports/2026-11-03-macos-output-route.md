# macOS 真实音频输出切换

在 M1 MacBook Pro 上，以 Flutter 公共控制器播放本地 H.264/AAC Matroska。两个端点为蓝牙 AirPods Pro 和内置扬声器。测试改变 Core Audio 默认播放设备，并针对播放器 PID 读取 HAL 的运行状态及其实际输出端点。每个成功阶段要求端点唯一匹配、所选音轨保持不变，且在至少一秒观测内媒体时间推进至少 900ms。测试使用设备端点观测，没有采集麦克风或声学信号。

## 保持原会话

AirPods 初始输出通过。切到扬声器后，默认设备确实变化，播放器进程的实际输出集合变空。公共状态仍为 `playing`，没有 failure，媒体位置连续 11.0 秒停在 3.669 秒。测试在 12 秒切换窗口到期时判定失败并恢复 AirPods。[回执](evidence/2026-11-03-macos-output-route/same-session/result.json) · [同步观测](evidence/2026-11-03-macos-output-route/same-session/observations.jsonl)

## 调用方显式重载

第二轮沿用原 Swift SDK 和 codec，前端增加受测试命令控制的公开 `load`。每次实际切换后，收集器观察到默认端点已变化、播放器 PID 停止输出，随后要求前端从当前公共媒体位置显式重载同一文件。两次调用由外部收集器触发。运行时没有自动切换会话。

| 输出端点 | 公共会话 | 请求起点 | 实际输出期间进度 |
| --- | --- | ---: | ---: |
| AirPods | apple-1-s1 | 0 s | 1.045 → 2.122 s |
| 内置扬声器 | apple-1-s2 | 2.591 s | 2.601 → 3.587 s |
| AirPods | apple-1-s3 | 5.085 s | 5.095 → 6.076 s |

末会话自然结束，测试应用和采集器均退出 0，最终默认设备为原 AirPods。两轮使用相同的原生 Swift SDK（SHA-256 前缀 `63049f36`）和 codec（`4a2083b4`）。本次验证覆盖真实设备间的显式重载恢复。该旧版 SDK 在会话失效后仍显示播放中。[重载回执](evidence/2026-11-03-macos-output-route/explicit-reload/result.json) · [设备观测](evidence/2026-11-03-macos-output-route/explicit-reload/observations.jsonl) · [公共事件](evidence/2026-11-03-macos-output-route/explicit-reload/public-events.jsonl)

## 修复后的公开错误与恢复

普通 macOS 受管播放现在也监听当前 AVAudioEngine 的配置失效通知。回调按音频队列代次检查归属，停止失效的输出并将既有错误交给会话。调用方从失败状态中的媒体位置显式重载。测试沿用上轮 Flutter 前端和相同 codec，使用重新编译的优化 Swift SDK `e27b5a10648bdeb86b05455d8b766f20be644f459ab558fe97aaa010541716a2`。

| 真实切换 | 旧会话公开状态 | 重载起点 | 新会话实际输出期间进度 |
| --- | --- | ---: | ---: |
| AirPods → 内置扬声器 | s1 failed，render.audio_engine_failed | 2.762 s | s2，2.774 → 3.819 s |
| 内置扬声器 → AirPods | s2 failed，render.audio_engine_failed | 5.271 s | s3，5.281 → 6.284 s |

两次重载均在采集器同时观察到原会话公开失败和 HAL 输出停止后发起。真实端点的验证范围为本机本地 H.264/AAC。既有 AV1 准入绑定旧版 SDK 的映像哈希，新映像仍需独立取得资格。

最后一个会话自然结束，测试进程退出 0。完成时默认设备为原 AirPods。[验收回执](evidence/2026-11-03-macos-output-route/failure-reload/result.json) · [同步端点观测](evidence/2026-11-03-macos-output-route/failure-reload/observations.jsonl) · [公共事件](evidence/2026-11-03-macos-output-route/failure-reload/public-events.jsonl)

## 已准入 AV1 的真实设备往返切换

同一播放器进程在 AirPods Pro（103）和内置扬声器（91）间往返。Flutter 测试宿主使用正常公共注册、已签发的优化 Swift SDK 和对应档位，从本地 AV1/Opus 资格素材的 1170 秒处开始播放。每次切换均先观察到旧会话公开报告 `render.audio_engine_failed` 且 HAL 输出停止，再通过公开 load 从失败位置重载。三个会话均使用软件解码，保留同一选中音轨。采集器在每个阶段核对 PID 的运行中输出设备和实际推进的媒体时间。[对应准入档位](2026-11-03-macos-route-av1-qualification.md)

| 运行中唯一输出设备 | 公共会话 | 输出期间的媒体时间（秒） |
| --- | --- | ---: |
| 103 | apple-1-s1 | 1170.000 → 1170.998 |
| 91 | apple-1-s2 | 1171.514 → 1172.485 |
| 103 | apple-1-s3 | 1173.174 → 1174.441 |

末会话自然完成，应用退出 0，最终默认设备为原 AirPods。此次往返覆盖本地文件。[回执](evidence/2026-11-03-macos-av1-output-roundtrip/result.json) · [公共事件](evidence/2026-11-03-macos-av1-output-roundtrip/public-events.jsonl) · [逐次端点观测](evidence/2026-11-03-macos-av1-output-roundtrip/observations.jsonl)

## HTTP Range AV1 的设备往返切换

使用同一已签发 SDK，经回环 HTTP 服务播放有限、可定位的 AV1/Opus 素材，从 1170 秒开始。每次 load 均使用独立查询标识。三个会话分别取得对应标识的 Range GET 206 回执，均使用软件解码。两次切换均先观察到旧会话公开报告 `render.audio_engine_failed`、进程音频输出停止，才从失败位置显式重载。HAL 核对的是同一播放器 PID 64166 的实际输出设备。

| 公共会话 | 唯一运行中输出（103 为 AirPods，91 为内置扬声器） | 首帧检查时已记录的 206 GET 数 | 输出期间媒体时间（秒） |
| --- | --- | ---: | ---: |
| apple-1-s1 | 103 | 3 | 1170.076 → 1171.110 |
| apple-1-s2 | 91 | 3 | 1171.634 → 1172.663 |
| apple-1-s3 | 103 | 3 | 1173.281 → 1174.301 |

最后一个会话自然结束，播放器退出 0，默认设备恢复为 AirPods。本轮覆盖回环 HTTP 和上述两个端点，USB 输出仍待实测。[验收回执与 Range 记录](evidence/2026-11-03-macos-http-av1-output-roundtrip/result.json) · [公共事件](evidence/2026-11-03-macos-http-av1-output-roundtrip/public-events.jsonl) · [同步设备观测](evidence/2026-11-03-macos-http-av1-output-roundtrip/observations.jsonl)
