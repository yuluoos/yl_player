# macOS AV1 内置扬声器输出验证

在 MacBookPro17,1（系统构建 26A434）上运行已签发的公共 Release 宿主。文件和受管 HTTP 均播放 AV1/Opus，经过三次定位并自然结束。Core Audio 针对同一播放器 PID 61780 观测到内置扬声器（设备 ID 91）是该进程唯一的运行中输出端点。应用清单 SHA-256 为 `db06f87bc02e28145ce0fe74c7a5804d1a9edcd8c9c7e734bcd58f2b2cff5ec8`。[采集回执](evidence/2026-11-03-macos-av1-speaker-output/result.json) · [准入档位](2026-11-03-macos-route-av1-qualification.md)

| 采样窗口 | 文件有效输出采样 | HTTP 有效输出采样 |
| --- | ---: | ---: |
| 初次播放至首次定位前 | 33 | 33 |
| 定位到 2000 ms 并恢复 | 4 | 3 |
| 定位到 1250 ms 并恢复 | 4 | 4 |
| 定位到 0 ms 并恢复 | 4 | 2 |
| 最后一次恢复至自然结束 | 33 | 34 |

只有完整落在公共事件窗口内的 HAL 查询才计数。定位窗口从公开 seek 命令返回开始，至播放位置进入对应目标区间结束。十个窗口共 154 个样本，每个样本的默认输出、实际运行状态和进程输出设备均匹配。两路分别完成七次颜色回读，HTTP 服务记录了 Range 206。这里验证到 HAL 设备端点为止，扬声器的声压、左右声道分离度未测量。[带时间戳的公共事件](evidence/2026-11-03-macos-av1-speaker-output/events.json) · [逐次 HAL 观测](evidence/2026-11-03-macos-av1-speaker-output/samples.json)
