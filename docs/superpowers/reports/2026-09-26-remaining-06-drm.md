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

## Task 2：配置、许可证传输与旧适配器准入（2026-09-27）

基线 `b96ad0c7af9e55a5781928c8ec1f30dcd6ba3964`。本项增加公开 Widevine/FairPlay 配置、不可变脱敏字节容器和独立 raw-binary 许可证 POST 客户端。完整签名、限额、错误表和生命周期边界见 [契约第 6/7 节](../specs/2026-09-26-drm-contract.md#6-已实现的-dart-配置与许可证-post)。无商业 SDK，无原生解密或输出保护结论。

### 交付与行为

- Widevine 要求显式 DASH，FairPlay 要求显式 HLS 及宿主提供证书/content ID；平台和 cenc/cbcs 下限独立验证。保留原有 category/scope 和 Pigeon enum ordinal，schemaMajor 仍为 4。
- 许可证 POST 与媒体 GET 分离，默认 HTTPS、默认不重试/不重定向。显式幂等才可重试最多两次；显式开启重定向也仅限同源 307/308 两跳。跨源既不传凭据，也不传 challenge。
- 单次 challenge ≤1MiB、响应 ≤4MiB；全请求总期限覆盖正文与重试；每客户端最多四个并发请求。关闭/取消中止连接且禁止迟到结果。401/403 表示拒绝；410/其他 HTTP 错误不推断过期。
- 现有 controller 在取消当前 clear 候选之前拒绝不支持 DRM 的请求，双端 codec 再次拒绝，防止旧 DTO 静默丢弃 DRM 配置后尝试 clear 播放。没有让当前适配器声明 protected-playback 能力。

### 实际验证

新增配置 4 项、真实 loopback HTTP/TLS 14 项、controller 准入 2 项、双端 codec 各 1 项，共 22 项。HTTP 记录器断言原始 POST 字节、实际次数、同源凭据、跨源零请求、断连后不重发、显式重试、流式正文超时、取消后迟到响应、响应超限、并发上限与 close。测试使用自有测试字节和本地 HTTP 服务，不是有效许可证，也不证明密钥可安装。

已观察配置/客户端缺失时 RED；旧适配器准入的行为 RED 是 assess 被错误接受、双端序列化为 clear、pending clear load 被取消。实现后 GREEN。四包完整 Dart 回归 **381/381**，无跳过；静态分析 **0 issues**；公开 API 表面检查及双端 Pigeon 生成一致性均通过。Task 2 没有改原生源码或协议生成物，未重复运行 Task 1 模拟器实播。

```sh
flutter test packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test
sh tool/check_public_surface.sh
sh packages/yl_player_apple/tool/check_pigeon.sh
sh packages/yl_player_android/tool/check_pigeon.sh
dart analyze packages/yl_player/lib packages/yl_player/test/drm_admission_test.dart packages/yl_player/test/drm_license_client_test.dart packages/yl_player_platform_interface/lib packages/yl_player_platform_interface/test/drm_contract_test.dart packages/yl_player_apple/lib/src/apple_codec.dart packages/yl_player_apple/test/drm_codec_test.dart packages/yl_player_android/lib/src/android_codec.dart packages/yl_player_android/test/drm_codec_test.dart
```

本机 macOS27/M1，Flutter3.44 / Dart3.12；HTTP/TLS 请求发生在 Dart VM 本地受控服务，不代表任何特定 license provider 或最低系统实测。证据在本计划忽略目录内的 `license-{contract,http,admission}-red.log`、对应 green 日志、`license-dart-all.log`、`license-dart-final.log`、`license-analysis-final.log`。双端 Pigeon check 退出码 0，无生成物差异。

### 决定与仍未完成

本项采用原始二进制服务契约；宿主提供授权证书及 content ID，未猜 JSON/base64/SPC/CKC 包装规则，使用其他供应商格式需要后续显式适配。生产受保护 view attachment、密钥 challenge/response Pigeon 桥接从 Task 2 移至 Task 3，随原子会话生命周期落地；代价是 Task 2 配置/网络可用仍不能授权播放。此时新增未接原生的占位桥接会制造不实能力，所以 schema4 继续明确拒绝。

Task 3 尚需系统密钥请求/安装/更新、代际校验、候选回滚、后台恢复、受保护显示与错误事件；Task 4 尚缺授权流、服务/证书和物理设备验收。HTTP 200 不等于授权成功，HTTP 错误不能当作过期，clear 原型不等于受保护播放。CAP-DRM 仍未完成。

### 独立复核与修复

独立只读复核发现 1 项 Important：Dart3.12 的 HttpClient 强制关闭不能及时中断已经完成 TCP、尚未完成 TLS 的握手；调用方返回超时/取消后连接仍可能占用资源。新增两个测试先复现对端 EOF 未到达，再修复为显式持有原始 TCP 连接直到 TLS 完成，并由内部适配器把已验证 RawSecureSocket 交给 HttpClient。取消/超时各重复五次，均要求上一连接收到 EOF，防止配额释放后积累隐藏连接。

另补测系统默认信任拒绝自有证书（零 HTTP 请求），内部私有 CA 上下文成功传输 1MiB 二进制请求和响应；没有开放生产证书忽略回调。夹具含刻意公开的测试服务器私钥，不能用于生产；证书到期 2027-09-27，更新说明见 `test/fixtures/drm_tls/README.md`。原始 TLS 适配器只承担 I/O 与背压，HTTP 解析仍由 HttpClient 执行。修复后全套 381/381，通过；0 静态问题，无剩余 Critical/Important/Minor。TLS RED 日志 `license-tls-red.log`，最终 GREEN 见 `license-dart-final.log`。未重派复核；本轮修复由行为 RED→GREEN 与完整回归证明。

复核未独立重跑的测试由实施者实际运行。真实服务协议、证书资源、系统密钥生命周期、物理保护及字幕/外接仍按 Task 3/4 门槛保留，不借本地 TLS 测试推导支持。

### Task 2 最终实现/测试 SHA-256

- `packages/yl_player_platform_interface/lib/src/drm/drm_config.dart`：`ed61fc80db045943174bee54d5ff3481642d590b55e9015d1701664e82bef866`
- `packages/yl_player/lib/src/drm/license_client.dart`：`5e4792d421defbf8b827279a9e2a8ebbdd9d61b30bcda71a3ca53fd0e4f5c761`
- `packages/yl_player/lib/src/drm/license_io.dart`：`697377d74b85428ecf06d9aa4ec9050c4cb50d0167e35d63639b09929c513e52`
- `packages/yl_player/lib/src/drm/license_secure_socket.dart`：`e840dd82f87e6dd1e31bb82d84a9bdc7ec78f662610d7219ddd562344bd9cc6d`
- `packages/yl_player/lib/src/drm/license_stub.dart`：`ea85799c71e1d7b8b51ac024b8c16d8fa60cd03ffa20ff20ce444405b65bf7ea`
- `packages/yl_player/lib/src/player_controller.dart`：`58669e603ea52371d1895a7f1a3ef21709acc39cd506fdee612965874a904bc6`
- `packages/yl_player_apple/lib/src/apple_codec.dart`：`c3ae9c57ca97527c6c3ace972cf0ebc9c035d019f2c30a6946e9a99845ff423f`
- `packages/yl_player_android/lib/src/android_codec.dart`：`9e238bd672b9730b39fbdf476f755a32620f9a66c99062fc36f29b0d986986d0`
- `packages/yl_player/test/drm_license_client_test.dart`：`d692bc5429917c502753006f4d14c931809e446fb2c44717f470751d50b980a9`
- `packages/yl_player/test/drm_admission_test.dart`：`412d34576c6723e1132138cb272d64f109027394d0f2b9ebb818574077c61286`
- `packages/yl_player_platform_interface/test/drm_contract_test.dart`：`8f2599ed23ee456228cf423daafb3a409a2f87fa322a6fa191e5d85ba1e934c8`
- `packages/yl_player_apple/test/drm_codec_test.dart`：`5a44dbee03a18c1f0c0601b6575d3ec768bce817c525c7634e9266c7efc22a79`
- `packages/yl_player_android/test/drm_codec_test.dart`：`6e4337ef86bb065c24bc496c6bba34cb1ff504e8989fefce3f59e7e648ea4510`
- `packages/yl_player/test/fixtures/drm_tls/ca.pem`：`c1ff500c39c2f977748507d3a1608919c5d1413e15ac5db64faf088c9be0cf71`
- `packages/yl_player/test/fixtures/drm_tls/server.pem`：`cd7f54d12cbd8ed18ea65e11efb3bfb4b230670e784dbe2dc6c4b36c2bdd5652`
- `packages/yl_player/test/fixtures/drm_tls/server.key`：`e72920b439cac67cff47d5c94de711d9a3635e8ffd1a002ba73e90fc13816e2b`
