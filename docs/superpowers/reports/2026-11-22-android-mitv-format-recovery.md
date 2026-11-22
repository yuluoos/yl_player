# 小米电视 HEVC 起播、音频播放头与同包格式矩阵

2026-11-22，Xiaomi MiTV-MTTP0（Android 9 / API 28，armeabi-v7a）使用同一份候选 Debug APK 跑完 44 格。40 格必测通过 **40/40**，本地 20/20，受管 HTTP 20/20。上轮未通过的 8 格，本轮通过 8/8。[本轮逐格结果](evidence/2026-11-22-android-mitv-format-recovery/matrix-after-rechecks.json) · [上轮 32/40 报告](2026-11-22-android-mitv-format-matrix.md)

## 三组复现与改动

- **HEVC 起播。** 旧包本地 MOV 能完成播放和三次跳转，但在音频还处于前两秒时已采到蓝色画面，红、绿两个标记没有合格的配对。设备日志显示 `OMX.MS.HEVC.Decoder` 先后为私有、公开两个 Surface 建立了解码器。现在该旧款解码器在可跳转的点播上切换公开输出时，先停止旧解码，再在新 Surface 上从播放器保留的位置重新准备，让新解码器从同步帧读取。最终包首轮的本地与 HTTP 共四格，在起播的第一个标记各采到 9–10 个合格配对，第二个标记各采到 12–13 个。相同 Surface、直播、不可跳转输入和已结束会话沿用现有路径。

- **DTS 与跳转后的音频观测。** 旧包在 DTS 已向 AudioTrack 写入 192,000 帧后仍有采集超时。诊断包在等待队列排空时增加进度采样，DTS 本地、AVI HTTP 和 PS 本地仍然超时。最终采集器在获取画面前，向 FFmpeg 回退引擎的工作线程请求一次真实播放头读数，同时记录读取时的单调时钟。令牌仅用于当前阶段的一张画面，沿用 200 毫秒的配对时限。每个色标仍需两个合格采样，音频时间跨度至少 100 毫秒。

- **PCM 取样开销。** 采集器保留对各 PCM 块采样率和声道数的检查，仅转换落入既定窗口的样本，取满后跳过额外转换。若用例失败，Android 现在会在释放前保留公开位置、状态、未完成阶段的像素与音频时钟，供区分播放故障和观测缺口。

中间候选的 DTS 本地、AVI HTTP 和 HEVC Main 10 HTTP 严格通过。PS 本地完成播放和三次跳转，但起播红色标记的两次配对只跨 96 毫秒，保留为失败。中间包的结果单独归档。[11 次诊断结果](evidence/2026-11-22-android-mitv-format-recovery/diagnosis-results.json) · [原始诊断记录](evidence/2026-11-22-android-mitv-format-recovery/diagnosis-runs.json.xz)

## 上轮未通过的 8 格

| 素材 | 本地 | 受管 HTTP |
| --- | --- | --- |
| `mov-hevc-aac` | 通过 | 通过 |
| `mkv-hevc-main10-aac` | 通过 | 通过 |
| `mkv-avc-dts` | 通过 | 通过 |
| `avi-avc-mp3` | 通过（上轮已通过） | 通过 |
| `ps-avc-mp3` | 通过 | 通过（上轮已通过） |

## 整轮复核

首轮必测通过 39/40，随后同包补验 1 次。上轮的 8 格均在首轮通过。首轮 HTTP MP4 的应用回执和音画数据完整，但 ADB 启动命令退出 255，采集器判为失败；重新冷启动后的同包补验通过。两格 MPEG-2 诊断与两格截断 MP4 保留各自的错误回执，分别为 `decoder.unsupported` 和 `container.unsupported`。[首轮结果](evidence/2026-11-22-android-mitv-format-recovery/matrix-result.json) · [首轮原始记录](evidence/2026-11-22-android-mitv-format-recovery/records.json.xz) · [补验选择与启动退出码](evidence/2026-11-22-android-mitv-format-recovery/recheck-selection.json) · [补验原始记录](evidence/2026-11-22-android-mitv-format-recovery/rechecks.json.xz)

矩阵 ID 为 `2977a986-5ad8-4ac5-afc0-99ea767f8b39`，APK SHA-256 为 `b1a2688eebebe1da11f0eb639d61285dbc15c8ccfff7994c98f6306f55a4dd0d`。每格均核验运行身份，最后再次从电视回读 APK 哈希。使用仓库的 `bound_matrix.summarize` 离线重放首轮、补验与选定回执，总数和逐格结果一致。Android JVM 回归共 636 项，633 项通过，3 项跳过。[设备、候选源码与构建回执](evidence/2026-11-22-android-mitv-format-recovery/device-build.json) · [冻结矩阵计划](evidence/2026-11-22-android-mitv-format-recovery/matrix-plan.json)
