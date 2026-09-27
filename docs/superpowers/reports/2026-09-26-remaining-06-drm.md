# P06 受保护输出与 DRM 执行报告

## Task 1：原生显示可行性（2026-09-27）

基线 `5b232ccddffde9a7360185451c62f72520af84d9`，既有 `codex/fel-integration` checkout。本轮交付 example Debug 原型及 [DRM 显示契约](../specs/2026-09-26-drm-contract.md)，没有增加生产 DRM 配置/解密/许可证，也没有改变 clear 默认播放路径或最低系统。正式授权播放仍为 `implementation=missing, verification=external_missing`。

### 当前路径审计与决定

| 维度 | 当前生产路径 | 决定 / 原型边界 |
| --- | --- | --- |
| Apple 输出 | AVPlayerItemVideoOutput 回读 CVPixelBuffer；native view 仍经 AVSampleBufferDisplayLayer 合成 | 受保护路径改为 AVPlayerLayer 直接显示，禁止从该路径读解密像素；原型只证明 clear 内容能接 Flutter platform view |
| Android 输出 | Flutter SurfaceTexture；候选为非安全 PlaceholderSurface | 新路线为 `setSecure(true)` 的 SurfaceView + 显式 hybrid composition；保护、解码器、密钥状态分别验，不能将请求标志当证据 |
| 首帧关联 | 既有像素/渲染 observer | Apple 当前 layer readiness，Android 当前 player+epoch callback；均需生产 session 四元组再接入，原型不等于生产命令事务 |
| 截图 | Apple 现有像素处理链不能作为 FPS 安全证明；Android texture 同样不能证明 secure output | 原型不截图、不 PixelCopy、不回读视频；截图抵抗性无验收结论 |
| 几何 | YlPlayerView FittedBox/RotatedBox，当前 native 表面和纹理共同布局 | 受保护路线由 native 负责 fit/crop/rotation；本轮验证宽高变化，旋转和裁切的实际画面仍待测 |
| 字幕 | 完整字幕/P02 未完成 | 独立 overlay 与节目时钟，不依赖解密像素；原型文字在视频外，仅为布局参考，不声明叠加/保护通过 |
| 外接 | 现有屏幕/像素输出逻辑无新 DRM 证据 | Apple probe 禁止 external playback；HDCP/外接保护需授权资源与实际输出链，且独立于原生 DV 信号 |

方案使用 AVFoundation/Media3 系统及开源能力，无商业 SDK。Android Widevine cenc 的官方 API 门槛是 19、cbcs 是 25，套用项目下限后分别是 API24、API25；API24 对 cbcs 必须明确拒绝。iOS15/macOS12 保持既有下限，AVContentKeySession 符号更早可用不表示本项目已有授权播放。来源及精确 bridge/view 类型见契约；当前 API 与保护能力均未对用户宣告为支持。

### 原型与媒体

- `tool/protected_output/AppleProtectedViewProbe.swift` 是两个 Apple Debug runner 嵌入源码的唯一来源，`sync_apple_probe.py --check` 进入 foundation 入口。只在 `#if DEBUG` 注册，iOS Debug.xcconfig 显式定义 DEBUG；Release/Profile 不包含原型。
- Android `src/debug/.../ProtectedViewProbe.kt` 只存在于 Debug APK；MainActivity 反射注册可选插件，release 找不到该类则继续普通注册。engine detach 时清空通道并释放原型播放器，view unmount 只 detach SurfaceView。
- 独立 channel `yl_player_example/protected_probe` 和 view type `yl_player_example/protected_probe_view` 不加入任何生产 Pigeon schema。create/replace/snapshot/dispose/reset/count 只服务本地 clear fixture，最多 4 个身份、文件上限 8 MiB；无网络或 license 调用。
- 媒体是已提交 `dash_timeline/period0` 的 video init 与四个 fragments，AVC Baseline 320×180/24fps/4s，来自自有色块生成器；测试临时拼接字节，无重封装。哈希沿用 `dash_timeline/SHA256SUMS`；合并后的 4413 bytes 文件 SHA-256 为 `c94d78ffb1f71bd0170cd712939ab1b8a8735ed17bce0eb15a55b7b171652b47`，不引入第三方流。原型静音，无音画同步主张。
- `pixelReadback=false` / `protectionVerified=false` 是原型范围声明；不能把这些常量的测试断言当作系统安全遥测。

### 行为验证与限制

新增 `integration_test/protected_view_probe_test.dart` 从 Flutter 真实 mount 原生 view，验证身份 71/72、两个首帧、时钟推进、240×135 → 180×220 尺寸变化、只替换 71 后 epoch=2 而 72 保持 1、dispose 后查询明确失效、另一播放器仍存活、unmount/reset 后注册表归零。没有从截图/像素取得首帧结论；Apple 看 layer readiness，Android 看系统渲染回调。

已观察行为 RED：macOS 缺少通道时抛 MissingPluginException(create)。前一次缺 import 的构建错误不算行为 RED。iOS 第一轮原型同样报 missing：经 pbx/二进制检查，Runner Debug 未定义 DEBUG（只有 RunnerTests 有），因此源码被条件编译排除；修正仅 example Debug.xcconfig 后重测。

三端原型各 **1/1** 通过、0 skipped；Android 原有 SegmentBase 公开回归 **2/2**、macOS/iOS 原有 HLS 公开回归各 **2/2** 通过。Dart 静态分析 0 issues，Swift canonical/copy 检查通过。独立只读复核无 Critical / Important / Minor。设备基线为本机 macOS27/M1/16GB、iOS27 iPhone18Pro 模拟器、Android16/API36 arm64 TV AVD（read-only/no-snapshot）。最低版本与物理设备未测。macOS foreground warning 不能解读为“前台可见”，测试只证明 readiness 与 native view 布线。

下列 **不计通过**：授权解密、Widevine L1/secure decoder、FairPlay 许可证及输出保护、HDCP、截图抵抗、屏幕实际观察、最小系统、旋转/crop 像素正确性、字幕 overlay、内存泄漏/长期表现、生产 YlPlayerSession candidate 原子回滚。原型 clear 测试不能解除任何这些门槛。

### 复现与本机证据

```sh
python3 -B tool/protected_output/sync_apple_probe.py --check
cd packages/yl_player/example
flutter test integration_test/protected_view_probe_test.dart -d macos
flutter test integration_test/protected_view_probe_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6
YL_ANDROID_DEVICE_ID=emulator-5580 sh ../../../tool/run_android_integration.sh integration_test/protected_view_probe_test.dart
```

日志：`view-red2.log`、`view-macos-final.log`、`view-ios-green2.log`、`view-android-green.log`、`clear-{macos,ios,android}-regression.log`、`view-analysis-final.log`。

忽略目录 `.superpowers/sdd/2026-09-26-remaining-06-drm/` 保存 RED/修复/三端运行日志、设备日志和源码哈希。这些是本机证据，不假称远端 CI。原型用实际 Flutter 集成入口发现运行，没有新 XCTest suite，因此不修改 canonical RunnerTests 总数。许可证传输与 Pigeon 变化从 Task 2 开始，本轮不以未运行的许可证测试冒充通过。

后续先做 P06 Task 2 的精确 DRM 配置/许可证 POST、重试与凭据契约；真实授权资源缺失只阻塞 Task 4。P01 未完成范围继续保留，P02 消费本契约的独立字幕合成边界。

### 本轮决定与验证归属

按总览提前推进 P06 可行性，保留 P01 未完成范围；代价是本轮不交付通用 DASH。原型独立于生产适配器，后续仍需桥接/会话/保护能力集成。独立复核未判断的实际 DRM、安全 decoder、HDCP、截图/物理显示、最低系统、几何/字幕/外接/长期表现及未来许可证/密钥生命周期均继续保留为后续门槛，不能通过 clear 测试解除；没有待处理 Minor。Android 执行结果和最终哈希由实施者实际验证。

### 最终源文件 SHA-256

- `tool/protected_output/AppleProtectedViewProbe.swift`：`413f7e24f8f1239be53430a7979bcaf2ca72c025e6f9a610a1a14fd009ac433e`
- `tool/protected_output/sync_apple_probe.py`：`efddc9378597fae2e8bc3f867a18a35e6262cffc3e54b8b117c221368de40970`
- `packages/yl_player/example/ios/Runner/AppDelegate.swift`：`14f52934dd2b163cca1c9f3ab2d24821591a759433c17f929b395d33f5ca78ab`
- `packages/yl_player/example/ios/Flutter/Debug.xcconfig`：`0f44dcd884f805a7cb63b77adc6e80a18cfd2d58e2b5b34b2deade3a3845396d`
- `packages/yl_player/example/macos/Runner/MainFlutterWindow.swift`：`de56a1b32e886d3ce91f48099a95f1b1c0a0068f6954ad8c6a5cde117c3d901e`
- `packages/yl_player/example/android/app/src/main/kotlin/dev/ylplayer/yl_player_example/MainActivity.kt`：`8e508c177ff3025522535e68e28f3cfa0713b86f8baafa53769d5f4fedd44ad3`
- `packages/yl_player/example/android/app/src/debug/kotlin/dev/ylplayer/yl_player_example/ProtectedViewProbe.kt`：`ebaa2063c6489d40b7427282f39c2c1002229db2dba14ce407e4db7b50e0cfc5`
- `packages/yl_player/example/integration_test/protected_view_probe_test.dart`：`f3665aa39972e533685c68d474b8ad1daa1afba59324324a9c7ed1a98cf061c0`
- `tool/check_foundation.sh`：`63005129c0ac99de1f1c0768c049170f1f6b7895b2e29752189385bc34f98fff`
