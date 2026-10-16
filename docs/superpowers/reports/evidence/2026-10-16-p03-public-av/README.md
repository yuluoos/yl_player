# 公开 Flutter Android 同次构建身份音画验收

2026-10-16，P03 已批准 Task 7 的续做。基线 `bd93560d8a952a4c1d0489ba8bcdd2d30d0d8299`。
没有修改长播放/弱网 ABR、软件准入、DRM 或公开播放行为。

## 通过范围与身份

`public-2` 的六个固定 clear/file 控制通过原始音画门禁 **6/6**，Flutter 框架最终测试结果通过，运行前后 APK 不变。

- run：`792f4c47-ce5c-4dea-ad31-4c464c06ab97`
- APK SHA-256：`fb1ecee4bb62911726cfd77d25d827e1c4153d423c33ba2dfffd4015e9ee4e9d`
- 制品：公开示例 `app-debug.apk`，Dart 集成测试与产品共用此容器；不是 release。
- 宿主冻结 SHA 后安装/启动；进程内以流式 SHA 校验实际安装 APK，结束后复验。无需将自哈希嵌入 Dart 再重建。
- `YlPlayerController`/`YlPlaybackSession` 执行所有命令，`YlPlayerView` 使用真实 Flutter 纹理；没有替换 ImageReader 或创建旁路播放器。
- 公开会话分别为 `a1-s1` 至 `a6-s1`，与对应原生会话一致；run UUID 和 APK SHA 同时进入每个原始阶段/PCM 窗口，不能跨运行借用记录。

| 控制 | 实际产品路线 | 实际音频解码器（Media3） |
| --- | --- | --- |
| AVC/E-AC-3 | native fallback | 由既有原生 PCM 路径验证 |
| AVC/DTS | native fallback | 同上 |
| AVC/FLAC | Media3 | c2.android.flac.decoder |
| VP9/Vorbis | Media3 | c2.android.vorbis.decoder |
| AVC/AC-3 5.1 | native fallback（Lo/Ro） | 由既有原生 PCM 路径验证 |
| PS/AVC/MP3 | native fallback | 同上 |

硬解身份为 `c2.goldfish.h264.decoder` / `c2.goldfish.vp9.decoder`。采集不更改产品回退或解码准入策略。

每项保留播放四个音调/色标、seek 1250/2250/0 ms、公开 ready/firstFrame/completed/dispose 与实际 AudioTrack 释放。Flutter 捕获真实 composition RGB；每张图像使用一次性消费时钟 token，采集需在新读 AudioTrack head 后 200 ms 内完成。原始 PCM 七窗口各 8192 帧，固定时间起点、频率、声道/Lo-Ro 与数据 SHA 由 Python 门禁重算。

## 负例与回归

- `public-1`：首版验收桥一次性读约 200 MB APK，超过模拟器应用堆；播放前崩溃，0/6。完整失败记录保留。修复为 1 MiB buffer 流式哈希。
- `negative-identity`：同一最终 APK，错误预期 SHA 在播放前拒绝，0/6。
- `negative-framework`：同一最终 APK 的六行原始数据 **6/6**，随后故意让 Flutter 测试失败；框架 `allTestsPassed=false`，总体 `scopeAcceptance=false`。不能用测试体提前写出的成功或 adb exit 0 冒充框架通过。
- `gate-red.log` → `gate-green.log`、`public-platform-red.log` → `python-tests-final.log`：拒绝 native-only/public 会话错配、缺公开生命周期、错误 pixel 来源和平台错配。最终 Python **47/47**（含复审后的控制集合检查）。
- `factory-red.log/xml`：未接线 fallback 观察工厂未被调用；接线后 JVM 测试先暴露未替身化的 Android SystemClock，再以边界替身修正测试环境。`factory-green-2.log` 验证真实可恢复 load 保留 session identity、激活 fallback 并返回公开 load reply。
- `android-unit-summary.json`：535 total，532 pass、3 既存 skip、0 failure/error。
- `dart-analyze-final.log`：新增 Flutter 测试与 API 注释无静态问题。
- `variant-absence.json`：普通 debug 和显式传 opt-in 的 release AAR 均不含观察类；只有 opt-in debug 包含。`release-absence-build.log` 保存实际构建。
- `native-regressions.log`：共享观察器、PCM 和格式解码原生回归 **23/23**。
- 独立最终复审无 Critical/Important；补齐唯一 Minor：启动前强制固定六控制各出现一次，缺失/重复均拒绝，`controls-red.log` → `python-tests-final.log`。
- `archive-recheck.json` 独立复算四次运行；`build-provenance.json` 保存最终 APK 与相关源码摘要；`manifest.json` 固定本目录归档字节。

## 复核与限制

各目录的 `plan.json` 冻结分母/路由/阶段/制品，`launch.json` 保存安装后启动命令；`rows.json.gz` 保留同会话原始 PCM 与像素，`status.json` 保存 Flutter 框架最终结果。用 `bound_av.validate(plan, rows)` 复算原始门禁；总体结果还必须检查框架通过、运行时身份和前后制品不变。负例框架行的 raw6/6 是预期，不得忽略 `result.json` 的总体 false。

环境为本任务专用 API36 arm64 TV 模拟器。当前只是公开 Flutter **Android debug 六控制**；不覆盖 Apple 公开路径、release 全矩阵、网络传输、最低系统/真机、物理扬声器/屏幕同步或持续热资格。`fullAcceptance` 固定 false，P03 Task7/8 仍有开放项。上一轮原生证据保持不变。
