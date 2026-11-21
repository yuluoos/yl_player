# Android HEVC Main 10 真机验收，2026-11-21

**OPPO CPH2065（Android 12，API 31）本地文件、受管 HTTP 两项均通过。** 加上此前 API 36 模拟器覆盖的 36 项，跨设备、跨构建累计覆盖 38/40 项。剩余两项是 AV1 的本地文件和 HTTP 播放。[此前的完整矩阵](evidence/2026-11-05-remaining-device-acceptance/android/matrix-result.json)

| 输入 | 播放及三次跳转 | 实际视频解码器 | 网络回执 |
| --- | --- | --- | --- |
| 本地文件 | 通过 | `c2.mtk.hevc.decoder`，硬解 | 本地文件源已校验 |
| 受管 HTTP | 通过 | `c2.mtk.hevc.decoder`，硬解 | 收到 6 个请求，交付 302341 字节，拒绝 0 个 |

两项均通过公开 Flutter 播放器完成首帧、播放结束、跳转至 1.25 秒、2.25 秒及 0 秒，并完成释放。每次都校验了 Flutter 画面像素和 PCM 采样，音频时钟来自 AudioTrack 播放头。设备安装包身份、源文件哈希、媒体请求归属及框架终态按各自适用的规则通过。相同 APK 串行执行，每项各运行一次。离线重放两份 ADB 原始输出后，矩阵校验器确认两项均通过。[原始采集及运行回执](evidence/2026-11-21-android-hevc-main10/records.json.xz)

源码提交为 `cb22d990`，APK SHA-256 为 `98c53dd600fa79812010b33efc63a74db2bc3c05ca28bf4ade0c5c5328ed3678`。使用 Flutter 3.50.0、本机 Gradle 9.5 和项目的 AGP 9.0.1 构建 Debug APK，入口为 `integration_test/bound_av_test.dart`，显式设置 `ylBoundAV=true`。本次构建使用 `skipDependencyChecks=true` 跳过 Flutter 构建工具的版本预检。两次实跑使用仓库现有的 Android 验收校验器。
