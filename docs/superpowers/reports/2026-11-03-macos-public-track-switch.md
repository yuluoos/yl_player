# macOS Flutter 公共 API 切换四音轨验证

同一份签名 macOS example 应用通过本地文件和受管 HTTP 分别加载四音轨 Matroska 素材。两个独立会话中的 Flutter 测试先播放默认轨至结束，然后在 2.5 秒处调用 `YlPlaybackSession.selectAudioTrack`。每次确认公共状态的会话 ID、原选中轨、目标轨和最终选中轨，恢复播放至自然结束，并采集该阶段的真实原生图像、音频消费时钟和转换后 PCM。八次切换均通过。[运行回执](evidence/2026-11-03-macos-public-track-switch/result.json)

| 切换 | 声道 | 文件最大绝对误差 | HTTP 最大绝对误差 |
| --- | ---: | ---: | ---: |
| AC‑3 → E‑AC‑3 | 2 | 0.00003903 | 0.00003903 |
| E‑AC‑3 → DTS | 2 | 0.000000391 | 0.000000391 |
| DTS → FLAC | 2 | 0 | 0 |
| FLAC → AC‑3 | 6 | 0.00004469 | 0.00004469 |

每次切换核对 2.6 秒处开始的 8192 个采样帧，覆盖全部输出声道。依据该轨原始包 PTS 和包内采样序号确定参考窗口。沿用 Dolby 和 DTS 的独立 Rust 参考及产品 Core Audio FLAC 的 FFmpeg 参考。峰值绝对误差要求低于 0.0002。每次切换还取得至少两次相隔 100ms 的可见蓝色标记读回，读回时显示时钟停止且真实音频消费位置处于对应标记区间。[原始观测](evidence/2026-11-03-macos-public-track-switch/rows.json.gz)

应用清单 SHA-256 为 `6713afe4cf7778182b02c07193305af51dfc34b05509ebaad9235874a7ca4a96`。本轮增加了测试素材及 Flutter 选轨步骤，载入的 Swift SDK 与 codec 映像沿用已通过矩阵的身份。文件和网络均由原生观测器核对实际来源。HTTP 服务核对请求标识并记录 2 次请求、1,985,442 字节、0 次拒绝。两路均确认公开 dispose、原生释放和字节账本归零。[冻结计划](evidence/2026-11-03-macos-public-track-switch/plan.json) · [公共事件与框架日志](evidence/2026-11-03-macos-public-track-switch/flutter-transcript.txt)

Flutter 测试框架与原生观测通道均报告通过，采集器在收到完成状态后终止其拥有的桌面宿主，记录的宿主退出码为 −15。整个采集命令退出 0。离线重放从原始事件和窗口得到相同的八项结果。旧选轨 ID 的负对照在状态验证处失败，将 E‑AC‑3 窗口替代新 DTS 窗口时，首个样本误差为 0.012387，超过门槛。[负对照](evidence/2026-11-03-macos-public-track-switch/negative-controls.json)

本次验证范围为 macOS M1 上的公共文件和受管 HTTP 切轨。公共路径的独立比较覆盖每次切换后的指定 PCM 窗口；完整尾段样本已由此前的原生后端测试覆盖。输出设备切换及跨设备验收仍待完成。[原生切轨验证](2026-11-03-macos-switch-independent-pcm.md)
