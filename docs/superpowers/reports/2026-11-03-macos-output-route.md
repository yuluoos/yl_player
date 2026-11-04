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
