# OPPO Android 完整格式矩阵

2026-11-21，OPPO CPH2065（Android 12，API 31）在同一设备、同一 APK 上跑完 44 格。**含定向补验，40 项必测通过 38 项**。本地文件和受管 HTTP 各通过 19/20，剩余两项都是 AV1/Opus MKV。两种输入均从公开播放器收到不可重试的 `decoder.unavailable`。[逐格结果](evidence/2026-11-21-android-oppo-format-matrix/matrix-after-rechecks.json)

| 输入 | 必测通过 | MPEG-2/MP3 诊断 | 截断 MP4 |
| --- | --- | --- | --- |
| 本地文件 | 19/20 | `decoder.unsupported` | `container.unsupported` |
| 受管 HTTP | 19/20 | `decoder.unsupported` | `container.unsupported` |

每项独立启动公开 Flutter 播放器。通过项均校验应用与样片身份、首帧与播放完成、三个跳转位置、画面与 AudioTrack 播放头及 PCM 的配对、音频输出关闭和会话释放。HTTP 项另核对受管请求回执。两项 MPEG-2 诊断和两项损坏输入单独保留，分母为 40 项必测。

## 首轮与补验

首轮执行 44/44 格，必测通过 35/40。本地 AVI、本地无 cues 的 MKV、HTTP HEVC Main 10，以及本地 MPEG-2 诊断的启动日志均给出 `LaunchState: UNKNOWN (0)`，采集器没有取得对应测试回执。四项分别用新的 run ID 补验，保留原矩阵 ID 和 APK。三个必测项通过，本地 MPEG-2 取得与 HTTP 一致的拒绝回执。首轮和补验原始结果分别归档。[首轮结果](evidence/2026-11-21-android-oppo-format-matrix/matrix-result.json) · [两轮启动记录与选择依据](evidence/2026-11-21-android-oppo-format-matrix/recheck-selection.json)

## 构建与原始记录

矩阵 ID 为 `8f851c24-27d6-4ed7-b76a-1e1c9eeae2a7`。复用此前 HEVC Main 10 真机验收的 Debug APK，SHA-256 为 `98c53dd600fa79812010b33efc63a74db2bc3c05ca28bf4ade0c5c5328ed3678`。该 APK 基于 `cb22d990` 构建，本次仓库版本为 `76b48a9a`，两者之间播放器源码和矩阵工具一致。所有采用的 44 格均通过运行身份与 ADB 提取校验，矩阵结束后再次核对 APK 哈希。离线使用 `bound_matrix.summarize` 重放原始采集并复核最终计数。[矩阵计划](evidence/2026-11-21-android-oppo-format-matrix/matrix-plan.json) · [首轮原始记录](evidence/2026-11-21-android-oppo-format-matrix/records.json.xz) · [四项补验原始记录](evidence/2026-11-21-android-oppo-format-matrix/rechecks.json.xz)
