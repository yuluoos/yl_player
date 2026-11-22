# 小米电视 Android 格式矩阵（同机同包）

2026-11-22，Xiaomi MiTV-MTTP0（Android 9 / API 28，32 位 armeabi-v7a）用同一个 Debug APK 跑完 44 格。40 格必测最终通过 **32/40**，其中本地 16/20，受管 HTTP 16/20。另有两格 MPEG-2 诊断和两格损坏输入。[最终逐格结果](evidence/2026-11-22-android-mitv-format-matrix/matrix-after-rechecks.json)

## 逐格结果

| 素材 | 类型 | 本地文件 | 受管 HTTP |
| --- | --- | --- | --- |
| `mp4-avc-aac` | 必测 | 通过 | 补验通过 |
| `mov-hevc-aac` | 必测 | 画面与音频时钟配对不足 | 画面与音频时钟配对不足 |
| `mkv-avc-aac` | 必测 | 通过 | 补验通过 |
| `webm-vp9-opus` | 必测 | 通过 | 通过 |
| `flv-avc-mp3` | 必测 | 补验通过 | 通过 |
| `ts-avc-ac3` | 必测 | 通过 | 通过 |
| `ps-mpeg2-mp3` | 诊断 | `decoder.unsupported` | `decoder.unsupported` |
| `avi-avc-mp3` | 必测 | 补验通过 | 音频消费时钟 12 秒超时 |
| `mkv-av1-opus` | 必测 | 通过 | 补验通过 |
| `mkv-avc-eac3` | 必测 | 通过 | 补验通过 |
| `mkv-avc-dts` | 必测 | 音频消费时钟 12 秒超时 | 音频消费时钟 12 秒超时 |
| `mkv-avc-flac` | 必测 | 通过 | 通过 |
| `webm-vp9-vorbis` | 必测 | 通过 | 通过 |
| `mkv-hevc-main10-aac` | 必测 | 画面与音频时钟配对不足 | 画面与音频时钟配对不足 |
| `mkv-avc-ac3-51` | 必测 | 通过 | 通过 |
| `mkv-avc-aac-no-cues` | 必测 | 通过 | 通过 |
| `mp4-truncated` | 损坏输入 | `container.unsupported` | `container.unsupported` |
| `mkv-avc-opus` | 必测 | 通过 | 通过 |
| `mkv-avc-opus-silk` | 必测 | 通过 | 通过 |
| `mkv-avc-opus-hybrid` | 必测 | 通过 | 通过 |
| `mkv-avc-vorbis` | 必测 | 通过 | 通过 |
| `ps-avc-mp3` | 必测 | 音频消费时钟 12 秒超时 | 通过 |

## 8 格必测未通过的阶段

- **MOV/HEVC 和 MKV/HEVC Main 10，本地与 HTTP 共 4 格。** 播放器报告解码器为 `OMX.MS.HEVC.Decoder`，均完成自然播放、三次跳转和释放。补验的四次起播都没有采到与前两个色标匹配的画面和音频时钟样本，校验器返回 `pixel_audio_pair_missing`。
- **MKV/AVC/DTS，本地与 HTTP 共 2 格。** 两轮都收到了首帧，随后等待原生音频消费进度达到目标，12 秒超时，未进入跳转阶段。
- **AVI/AVC/MP3 的 HTTP 和 PS/AVC/MP3 的本地，共 2 格。** 两轮都完成自然播放，且收到跳转至 2.25 秒的命令回执。跳转后等待音频消费进度达到目标时超时。AVI 本地和 PS 的 HTTP 均取得通过回执。

## 同包核验与补验

构建基于 `54acfa18`，入口为 `integration_test/bound_av_test.dart`。APK SHA-256 为 `5b1defc43f39be508d537ca39bd517f87ec7ab116fe77484fb01fd1c9bb14e94`，矩阵 ID 为 `1b9e98f7-7494-467c-8a41-8a84a8de5b3f`。最终安装包回读哈希与冻结文件一致，44 个选定回执各有独立运行 ID，均通过身份绑定及原始 ADB 输出提取校验。[构建、设备与启动记录](evidence/2026-11-22-android-mitv-format-matrix/device-build.json) · [冻结计划](evidence/2026-11-22-android-mitv-format-matrix/matrix-plan.json)

首轮本地 MP4 通过。HTTP MP4 在重复安装同一 APK 后，启动记录显示小米桌面的 TranslucentActivity 占据前台，未产生本次运行的完成回执。随后采集器在每次启动前读取设备上单一安装包的 SHA-256，完全匹配就跳过重装，再强制停止并冷启动播放器。原有样片、播放和释放、三次跳转、画面与 AudioTrack 播放头及 PCM 配对、受管 HTTP 请求的验收条件均保持原值。

首轮必测通过 26/40。其后以同一 APK 和矩阵 ID 对首轮未通过的 14 格执行 15 次定向补验。AV1 HTTP 首轮在播放完成后收到 `player.disposed`。第一次补验的音画样本通过校验，但 ADB 启动命令退出 255，该次仍记失败。第二次补验取得完整通过回执。AV1 本地在首轮通过。

原始记录包括首轮失败和全部补验。补验通过时选用该次回执，重复失败且首轮已有完整证据时保留首轮。使用仓库的 `bound_matrix.summarize` 重放原始记录并核对总数。[首轮结果](evidence/2026-11-22-android-mitv-format-matrix/matrix-result.json) · [首轮原始记录](evidence/2026-11-22-android-mitv-format-matrix/records.json.xz) · [补验记录](evidence/2026-11-22-android-mitv-format-matrix/rechecks.json.xz) · [逐格选择](evidence/2026-11-22-android-mitv-format-matrix/recheck-selection.json)
