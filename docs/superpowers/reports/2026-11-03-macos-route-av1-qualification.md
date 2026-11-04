# 音频路由修复后的 macOS AV1 准入

提交 `efe30316` 对应的优化观测 SDK 已通过单线程 AV1 资格验证。签发档位绑定 MacBookPro17,1、系统构建 26A434、Swift 映像 `e27b5a10648bdeb86b05455d8b766f20be644f459ab558fe97aaa010541716a2`、codec 映像 `4a2083b42c52de082d170f1aced30c6fff67b8e93e40961068b2b2ac0e62dd5d`，以及 320×180、24 fps、Main 8-bit 4:2:0 配置。[签发档位](evidence/2026-11-03-macos-route-av1-qualification/yl-player-qualified-av1.json)

沿用此前的冻结协议和资格宿主，仅替换 Swift 框架并重新签名。两轮均先完成文件和 HTTP 的暂停、定位、颜色回读及实际系统帧计数检查，再连续播放完整素材。每轮解码 28,904 帧，包含一帧预览和 28,903 帧定时显示。两轮自然结束，应用和系统丢帧、系统损坏帧、时钟过期均为零。[协议](evidence/2026-11-03-macos-route-av1-qualification/protocol.json) · [进程回执](evidence/2026-11-03-macos-route-av1-qualification/pair-progress.json)

| 指标 | 基线 | 独立复验 |
| --- | ---: | ---: |
| 连续段结束时间 | 1204.674 s | 1204.691 s |
| CPU 峰值（ms/秒） | 221.012 | 238.850 |
| 单次解码峰值（ms） | 6.656 | 6.797 |
| 最大时钟年龄（ms） | 21.352 | 22.577 |

首轮按预定规则冻结 CPU 上限 277 ms/秒，单次解码沿用 42 ms 上限。第二轮在相同制品和冻结预算下通过。[基线回执](evidence/2026-11-03-macos-route-av1-qualification/baseline/receipt.json) · [复验回执](evidence/2026-11-03-macos-route-av1-qualification/verification/receipt.json)

将签发档位装入正常公共注册的 Release 宿主，严格签名及两个映像哈希校验通过。公共路径在 18.514 秒内完成文件和 HTTP Range 两路真实软件解码、三次暂停定位及画面回读，每路均自然结束并释放。验证宿主位于 `build/macos-route-av1-efe30316/qualified-public.app`。完整格式矩阵的既有证据仍绑定其原始制品。[公共回执](evidence/2026-11-03-macos-route-av1-qualification/public/receipt.json) · [证据清单](evidence/2026-11-03-macos-route-av1-qualification/sha256.json)
