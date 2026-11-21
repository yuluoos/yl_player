# Android AV1 硬解缺失回归

2026-11-21 在 OPPO CPH2065（Android 12，API 31）上运行 `decoder_budget_test.dart`。公开播放器以 `hardwareRequired` 加载项目的 AV1 对照样片，抛出 `YlPlayerException`。用例确认 `failure.code == decoder.unavailable`、`failure.retryable == false`，输出 `actual-unavailable-nonretryable`，完成释放并通过 Flutter 测试。[用例源码](../../../packages/yl_player/example/integration_test/decoder_budget_test.dart) · [真机回执](evidence/2026-11-21-android-av1-hardware-required/receipt.json)

本次覆盖 ERR-08 的硬解不可用分支。Android 格式播放累计仍为 38/40，AV1 本地文件和 HTTP 成功播放两项待有相应硬解的设备验证。[格式进度](2026-11-21-android-hevc-main10.md)

测试 APK 由提交 `970b7f72` 的源码和现有测试入口构建。使用本机 Gradle 9.5 离线构建时启用了 Flutter 的 `skipDependencyChecks` 构建参数。安装后读取设备 APK 的 SHA-256，与构建产物逐字节哈希一致。回执记录了这次启动的进程、测试分支标记和框架终态。
