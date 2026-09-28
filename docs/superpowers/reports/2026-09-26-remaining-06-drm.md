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

## Task 3A：Android 系统密钥生命周期边界（2026-09-27）

基线 `6e45451f35479e2da485e09f7087a79454cc6d07`，沿用干净的 `codex/fel-integration` checkout。本次交付内部 `YlDrmKeySession` 与真实系统 API 的 `YlWidevineDriver` 实现及系统 fake 测试；**没有将它们接到生产 Media3、受保护显示、Pigeon 或 Dart 许可证客户端，Task 3 整体仍未完成**。生产适配器继续在 admission 阶段拒绝 DRM，clear 生产路径没有改动。

### 行为与边界

- 每个候选拥有独立 driver，身份包含 player/surface/session/generation，另外使用 epoch/requestId 区分后台重建与密钥更新；失效先于取消和外部清理，迟到响应不安装。后台恢复创建新的系统对象；dispose 幂等。传输回包、生成的 challenge、内部初始数据使用有界副本，许可证安装用的副本在调用后清零。
- HTTP 成功及 provideKeyResponse 返回不等于密钥可用。仅当前非空且全部 usable 的系统状态确认可用；pending 撤销该状态，后续 KEY_REQUIRED 可直接请求更新。重复在途更新合并，初始加载有排队更新时不提前完成 ready；请求及等待系统状态有期限。
- owner dispatcher 加 mutex 串行执行系统调用与状态转换，防止内联系统回调丢失或覆盖 failed；失败候选不关闭其他实例。许可证拒绝不推断过期；仅系统 expired 状态/事件产生 `drm.license_expired`，输出限制返回 `drm.protection_insufficient`。
- driver 请求并读取实际 per-session HW_SECURE_ALL，低于该级别时释放并拒绝，无 L3 fallback。API24–27 无本实现要求的公开 per-session 查询，明确拒绝保护准入；API28+ 仍须实际证据，整包 API24 下限不变。L1 等级不证明安全 decoder、SurfaceView、HDCP 或实际播放。
- 不使用 CDM defaultUrl、不自行联网、不混用媒体 GET、不提取内容密钥。需要 provisioning 时返回独立 `drm.provisioning_required`；实际 provision 传输尚未接入。新增的 `drm.session_failed` 等错误使用固定指导信息；Dart 与 native 分类一致，Pigeon schema4 和既有 wire enum ordinal 不变。

### 实际验证

本机 macOS27/M1、JDK17、compileSdk36、现有 Media3 1.11.0，Android 测试为 JVM/Mockito 系统边界测试，**没有物理 MediaDrm 或授权播放证据**。新状态机/driver 19 项全部通过；Android 全套发现 **422** 项，**419 通过、3 跳过、0 失败**。跳过的是既有 `YlRtmpExtractorTest` 的三个独立 MediaMTX peer 用例（AVC/AAC、video-only、ACK windows），本轮未提供对应外部服务，不计通过。

四包 Dart **382/382** 通过；新增错误分类测试观察到 network 与 platform 不符的 RED 后修复；静态分析 0 issues、公开 API 表面和双端 Pigeon check 通过。原生全套包含原有候选替换、恢复、网络、clear 路径的逻辑回归；本次未重跑模拟器媒体实播，不将单元测试写成真实播放验收。

```sh
cd packages/yl_player_android/example/android
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :yl_player_android:testDebugUnitTest
# 仓库根目录
flutter test packages/yl_player_platform_interface/test packages/yl_player/test packages/yl_player_apple/test packages/yl_player_android/test
dart analyze packages/yl_player_platform_interface/lib packages/yl_player_platform_interface/test/drm_contract_test.dart
sh tool/check_public_surface.sh
sh packages/yl_player_android/tool/check_pigeon.sh
sh packages/yl_player_apple/tool/check_pigeon.sh
```

新增 API 缺失的 RED 见 `key-android-red.log` / `key-driver-red.log`；行为 RED 见 `key-status-red.log`。最终输出位于本计划本机忽略目录的 `key-android-final.log`、`key-dart-all.log`、`key-dart-analysis.log`；原生测试发现由 Gradle 的标准 `src/test/kotlin` 和 JUnit XML 验证。

### 复核、决定与后续

独立只读复核发现 2 项 Important：pending 后 KEY_REQUIRED 无法发送更新，以及同步 install 回调可能丢失就绪/覆盖失败。已分别以事件序列和真正内联 dispatcher 复现，再用请求在途状态与 owner mutex 修复；UnconfinedTestDispatcher 会排队，不能用其通过来冒充重入验证。同步测试在撤销串行化修复时失败，恢复后通过。修复过程中另复现并修正排队续期 challenge 异常被新 requestId 掩盖的分支。日志 `key-review-red.log`、`key-reentrant-red.log`、`key-renew-error-red.log` 及最终全套 GREEN。无未处理 Critical/Important/Minor，未重派复核。

按平台分步交付是本轮决定：先建立系统边界，再接不同的输出/候选事务；代价是此提交本身不能播放 DRM。API28+ 实际等级门槛是另一决定，代价是 API24–27 保护能力仍拒绝，后续若扩展必须提出可验证的证据。复核未运行的测试由实施者执行；未判断的实际设备/CDM/服务/rotation、Media3/保护输出/Pigeon/Apple/候选事务、secure decoder/HDCP 都保留为 Task 3B/3C/4 的门槛，不能用本次 fake 解除。

下一项是 Task 3B 的 Android 受保护显示、Media3 candidate 原子切换及许可证桥接，随后是 Apple Task 3C。Task 4 仍缺授权流、服务/证书和物理设备验收；CAP-DRM 尚未完成。

### Task 3A 最终源文件 SHA-256

- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlDrmKeySession.kt`：`610bf1f0f2793ee3cef88439f5a476ff1baeb03cfa75b13e05277fc9a2b251bf`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlWidevineDriver.kt`：`675aad4c4ef640bbd95ea71283f129188177267d8615d64f6d6c3ab2dae780e2`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlFailureMapper.kt`：`1299026d6e1434f0dcfca4bdecf0fe1c4d4e8d58f5409795880fb990a5ae9294`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlDrmKeySessionTest.kt`：`c8d965594fa3dad838e1fc112cf99d6f4c018a907f734aa54cf6f1c202146c5f`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlWidevineDriverTest.kt`：`a936d2676ed5a7a9ec809f45dc40394a2774b9c83c3fe5c833da009caa3cfab4`
- `packages/yl_player_platform_interface/lib/src/drm/drm_config.dart`：`5d7394c18f7102a4fe4084d0b90cb553322cf8c09499515fc0236ea66c62c6ff`
- `packages/yl_player_platform_interface/lib/src/model/failure.dart`：`cee511ea7386bb96e2f2ab0920d829b8af22d20eead7582be7b994e036de165b`
- `packages/yl_player_platform_interface/lib/src/diagnostics/safe_diagnostics.dart`：`810d447142dd102281f01d7e0a4edc6f3b68e6d8ab37a72ed74915740b159827`
- `packages/yl_player_platform_interface/test/drm_contract_test.dart`：`f280f0712051a45e863c4eabad71203ce848632b2f4b1b096d294ac7e9773151`

## Task 3B1：内部 Media3 DRM 消费与引用所有权（2026-09-27）

基线 `5232f71`，沿用干净的 `codex/fel-integration` checkout。本次完成 Task 3B 的第一步：真正实现锁定 Media3 1.11 的 `DrmSessionManager`/`DrmSession` 接口，消费 Task 3A 系统密钥状态并提供 `FrameworkCryptoConfig`；**尚未接到生产 Media3 core/source factory、保护 view、候选事务或 Pigeon/Task 2 许可证客户端**。生产 DRM admission 继续拒绝，Task 3B 和 CAP-DRM 均未完成。

拆分是资源所有权的前置依赖：原先只有自主关闭的 key state machine，没有 Media3 decoder/source 引用消费者；若直接连接，失败时关闭系统对象可能抢先于 decoder 释放。现在密钥失效和底层资源释放分开，最后一个引用释放才实际关闭，先同步标记 released、再取消和清理。代价是本提交本身没有新增用户可播放的 DRM 场景。

已验证边界：相同初始化共享引用、不同 Period 初始化隔离、最多 4 个系统会话（含失败/清理中）、manager release 不抢关借用会话、重复 acquire/release 与事件订阅匹配、HTTP 成功不代表 usable、pending/续期撤回可用状态、拒绝/过期/超时独立、迟到回包与旧系统回调不安装到新会话、启动前取消零分配、异常关闭不逃逸为原始协程异常。回包增加不透明 exchangeId，区分同 output 下多个 CDM 会话。

系统 handle 仅以副本进入 FrameworkCryptoConfig，禁止 insecure decoder components，销毁时清零。DRM 格式严格验证 Widevine、cenc/cbcs、MP4 init payload 上限；多个不同 Widevine payload 明确拒绝，不猜测拼接，不使用 manifest/CDM 提供的 license URL。clear 格式返回 null session 不等于受保护 source 的 clear 准入，3B2 还必须验证实际轨道。

安全 selector 总是查询并筛选 secure codec，视频还需实际硬件 metadata；防止 Media3 内置的非 secure 重试。现有 metadata 证据需要 API29+，不能因 API28+ 已有 L1 证明就跳过此门槛，整包 API24 下限仍不变。selector 列表也不是实际初始化 decoder/secure Surface/HDCP 的证明，均留待 3B2 与真机验收。

本机 macOS27/M1、JDK17、compileSdk36、Media3 1.11.0。Android 全套 **436** 项，**433 通过、3 跳过、0 失败**；新增 manager 10、selector 3、driver 1 项全部通过。3 个跳过仍是既有 MediaMTX 独立 RTMP peer 用例（AVC/AAC、video-only、ACK windows），缺外部服务不计通过。公开 API 表面与双端 Pigeon check 通过，schema4 与 Dart 合约未变。本次没有 Dart 源码更改，未重复 Dart 全套，也未做模拟器媒体实播或物理 CDM 测试。

命令：`JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home packages/yl_player_android/example/android/gradlew -p packages/yl_player_android/example/android :yl_player_android:testDebugUnitTest`，及 `sh tool/check_public_surface.sh`、双端 `tool/check_pigeon.sh`。测试由标准 JUnit 发现；全套日志 `media3-drm-all.log`。缺新接口/类的 RED 见 `media3-drm-red.log`、`media3-codec-red.log`；关闭异常行为 RED 见 `media3-close-red.log`，随后全套 GREEN。

实际授权服务、设备 provisioning、物理密钥轮换、受保护显示/字幕/外接、实际 decoder 证据尚未验收，不从 fake 得出播放结论。后续先做 3B2 保护输出/候选事务，再做 3B3 bridge/transport，随后 Apple 3C；授权资源缺失仍只阻塞 Task 4 的真实验收。

### Task 3B1 复核与修复

独立只读复核发现 1 项 Important：DASH manifest 可以只声明 Widevine，PSSH 要等初始化分片提供；getCryptoType 若复用 acquire 的完整 payload 校验会误报 unsupported，导致轨道不能选择。新增 metadata-only probe → 提前 acquire 拒绝 → 带初始化数据 acquire 成功的回归，观察 `media3-probe-red.log` 失败后修复。探测不分配 driver、不发许可证请求；实际 acquire 的边界未放宽。没有 Critical/Minor，没有未处理复核项；单次修复后运行完整原生回归，最终日志 `media3-drm-final.log`，不重派复核。

复核未独立运行测试的部分由实施者实际执行。未判断项逐项保留：Task 2 的 POST/凭据传输未改动；候选失败/取消和当前播放的隔离仍需 3B2/3B3；安全 Surface/实际 codec/物理保护、授权 rotation/后台/seek、字幕/几何/外接/禁止回读均需后续组合与真机证据；Pigeon routing 尚未实现，exchangeId 不是桥接验证；Apple 仍为 3C。决定继续交付内部边界的代价是以上各项没有生产支持结论，不能通过本次单测解除。

### Task 3B1 最终源文件 SHA-256

- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlDrmKeySession.kt`：`d11421e0d06b9b5d376219814b4f41653e03a2f3f09f61006471c11df4920060`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlWidevineDriver.kt`：`62a8d13d3b17366b4ddb1d97439fb7e70ff5c8324bf38941302aea05f43fc918`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3DrmSessionManager.kt`：`c711d036674e22652adc25ba12e69db8be957d74fee39c89025200fb6151ea71`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlProtectedCodecSelector.kt`：`ed53ee56b02584fac8319e17da2995a80c3f6fe1fc95fabf6d907b238f055a87`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlWidevineDriverTest.kt`：`901d303dc68e8a3ce3cc5e1e66a76bb5354ec3b9c895c7326925d43e2e4e5817`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlMedia3DrmSessionTest.kt`：`91d2de36ab77f782f4f09f65b653fad97003fbeb1599ae090b52c08d83a9df90`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlProtectedCodecSelectorTest.kt`：`86c82eab950c7bc723a0bdc03d6e13b05585dd6172ce5be2f374bf220d8edda1`


## Task 3B2：Android 内部保护输出与候选事务（2026-09-28）

基线 `a623a0b`。本次把安全 SurfaceView 工厂、四元组身份 registry、secure PlaceholderSurface 候选/inspection output、3B1 DRM manager、Media3 DASH source 与原有原子替换/回滚协调器接通。实际初始化 codec 必须匹配已核实的 secure/hardware 候选，激活/恢复等待系统 keys usable；已选视频没有 Widevine 元数据不能以 clear 成功提交。保护路线拒绝普通 texture/output replacement 和 native fallback。首帧展示同时校验当前输出身份、渲染时间边界和成功的 worker ACK；画面按显示几何/PAR 等比居中。

公共 Dart descriptor/provider、Pigeon challenge/response/视图 ACK 和 Task2 传输连接仍为 3B3，公开 adapter 仍拒绝 DRM。此内部集成不代表公开受保护播放已可用，也没有真机保护结论。没有新增商业 SDK，Media3 1.11.0、包 API24、系统 L1 API28 与硬件 metadata API29 的门槛保持不变。

一次独立只读复核发现三个 Important：holder 销毁异步解绑、同一 Surface 的旧首帧被重新标记、插件新实例重复注册工厂被静默忽略。输出 replacement 非 active/inspection 分支的保护绕过从 Minor 提升为 Important 并一并修复。先观察 `protected-review-red.log` 三个行为失败、`protected-frame-red.log` 迟到首帧失败，再修复；`protected-review-green.log` 定向通过。新增真实线程等待断言覆盖销毁在 worker ACK 前不能返回，queued attach 在 worker 再核验 revision；注册拒绝不能留下可用 host。

集成核查另发现最终 CDM 关闭被排队，可能在 playback Looper 退出时丢失；`protected-cdm-close-red.log` 复现最后引用释放后尚未关闭，修复为同一 owner turn 内取消请求、清除 challenge/session handle、关闭 CDM，`protected-cdm-close-green.log` 通过。随后只做一次完整回归，不重派复核。

### 本项决定与边界

- 修正文档允许 holder 销毁异步停车的错误。正常销毁/dispose/retire 同步等待 worker native ACK，worker 不等待 main 续体或 registry mutex。代价是这个原生生命周期边界可能短暂阻塞主线程。厂商解绑超时触发停止/释放尝试和明确失败，未知安全资源继续隔离；未确认解绑不能标为 ACK，JVM 测试不能证明故障硬件已经停止使用 Surface。[Android 销毁契约](https://developer.android.com/reference/android/view/SurfaceHolder.Callback#surfaceDestroyed(android.view.SurfaceHolder))。
- 同一 Surface 重用前先安全停车，记录 monotonic 渲染时间边界，并在 worker 等待 1ms 后绑定；拒绝边界及以前的帧。代价为每次保护 attach 增加 1ms，换取毫秒时间戳相等时也不会误认旧帧。[Media3 首帧时间契约](https://developer.android.com/reference/androidx/media3/exoplayer/video/VideoRendererEventListener#onRenderedFirstFrame(java.lang.Object,long))。
- 复核曾怀疑 foreground/trim 绕过 readiness，经追踪实际 coordinator 路径确认先通过 restore 的 decoder/key 门槛；保留现有路由，后续不得把 adapter 直接调用误当成完整生命周期入口。
- 复核未判断的公共桥接、物理旋转/seek/字幕 overlay/外接保护仍属 3B3/Task4；secure audio policy 沿用 3B1，Task2 POST 凭据逻辑未变。代价是这些部分仍未得到本轮端到端验证。没有延期 Minor。

### 本地验证

macOS27/M1、JDK17、compileSdk36、Media3 1.11.0。标准 JUnit 发现 **454** 项，**451 通过、3 跳过、0 失败/错误**。3 项跳过仍为缺独立 MediaMTX 服务的既有 RTMP peer 用例（AVC/AAC、video-only、ACK windows），不计通过。最终日志 `protected-final.log`，Gradle BUILD SUCCESSFUL。公开 API 表面与双端 Pigeon check 通过，schema4/Dart 合约未改变。没有 Dart 实现改动，未重复 Dart 全套；没有模拟器媒体实播或授权物理 DRM 验收。

命令：`JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home packages/yl_player_android/example/android/gradlew -p packages/yl_player_android/example/android :yl_player_android:testDebugUnitTest`；`sh tool/check_public_surface.sh`；双端 `tool/check_pigeon.sh`。初始接口/行为 RED 另见 `protected-output-red.log`、`protected-ack-red.log`、`protected-view-red.log`、`protected-core-red.log`、`protected-transaction-behavior-red.log`、`protected-key-gate-red.log`、`protected-fallback-red.log`、`protected-geometry-red.log`、`protected-plugin-red.log`。

下一项为 3B3 公共桥接/许可证传输连接，再做 Apple 3C；Task4 的授权资源仍缺失。完整 CAP-DRM 继续保持未完成。

### Task 3B2 最终源文件 SHA-256

- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlCandidateVideoOutput.kt`：`4a15c509ee62ed46348f6127f372e23d77b427029c4f832b556d62295e50dede`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlDrmKeySession.kt`：`d9a0457e0d9ef6ea37c1b02e27d877753416f7bd08f0c82ff5f2a60378f95c8d`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlManagedAndroidEngine.kt`：`8818d75c2164b5e90c456ef22e2d93e4f96a56bc81eff2a3793c2d115545a1fc`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Core.kt`：`b1a307c94fa9ce0005908c812fc7d668437a93e6b75d764bcb72565bb274ef8f`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3DrmSessionManager.kt`：`fce63143c5ec1417b2ca8510f3aa8570210fdfbd081d773e3d2daed2471b5879`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Engine.kt`：`4286a3647f08940acfb3f88d803c71f7bb2d10928c284bf2ee85ca30d2a07d28`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMediaSourceFactory.kt`：`b956a2c1f9a47c75d2f36455a5f478476517d89be097b162b4d3025c18ab70a2`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`：`ab677a771381057b3492fe29ea808a09165da0d7eaa2f0f6c33bb64befd23c4a`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlProtectedCodecSelector.kt`：`9cd18b916702f491fdb41e8e801fddb8e6aac16545d289467fe927e200156396`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlProtectedViewFactory.kt`：`957514685a9fc15c3a46cc35fe0cb92ac9934907261b3304ab2dbf14fb467b97`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlProtectedViewRegistry.kt`：`00a322e0bf8adec43c96e91218d0dcbdf38f2937ba6422a7cbf83cb8fd5ba457`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSessionCoordinator.kt`：`d2d05622b14d3d08beedcbb42b24dd7193afebb45fe7237609541e74c0509a81`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSessionModels.kt`：`8b5ee68ac4229c2748f313ccf2d03d1ce722fd6c5f11d4aa33ab842be91b9e6f`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlMedia3DrmSessionTest.kt`：`f9e093cd4a34130f1e9c2ea1c9026a316c7b88df2eb90ea7583a30f2a4ed8130`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlMetricsCollectorTest.kt`：`0d598734a3920567be9260fb86fde118de95dd483244b22f02c80008b2d51890`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlPlayerRegistryTest.kt`：`b097f8d113315084c69cb76bd56480147bd4866c00c9d2d4914eeeb3938c92bc`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlProtectedCodecSelectorTest.kt`：`2057a92a6710232eee3d8e773841413333d4dd0a7a2bbc07ce7221e5a408178b`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlProtectedOutputTest.kt`：`29e3ec8c3dad64bc4c3d9cd6c3cbf3e3710648bd80b7153bc19475b1704e24c1`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlProtectedViewTest.kt`：`58143f2262356c96570650d511820f8ef1dfa1d2240a394b44ff437ad0d9c74a`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlSessionCoordinatorTest.kt`：`f76a50825ba11a7a0ee54e24d1f484f84727fe4525ffab28c6fd16e3d7c19938`


## 2026-09-28 Task 3B3：Android 公共 DRM/保护视图桥接

基线 `2518d4d`。本阶段完成 3B 工程集成；Android API29+ 可接收 Widevine DASH，保留系统 scheme、L1、实际安全硬件 decoder、secure output 和 keys usable 的逐会话检查。没有商业 SDK。Apple 仍待3C，授权内容与许可证服务仍缺，**没有真实受保护解密/物理输出通过结论，CAP-DRM 未完成**。

- Android wire 升为 schema5（Apple仍4，SPI仍2），Dart/native 必须同步升级。源消息仅携带 cbcs/timeout；许可证地址和凭据留在 Dart，由控制器可选 SPI delegate 接既有 Task2 有界 POST client。
- 独立 Pigeon challenge/response/cancel 与 view attach/detach/ACK 通道完整关联 player/surface/session/generation/load/epoch/request/exchange 身份；取消精确 pending load 不伤保留会话，迟到响应不安装。
- 公开描述符驱动显式 hybrid AndroidViewSurface；匹配当前 attach ACK 与帧 revision 才发布首帧。原生遮黑和 contain/center 布局，不经 texture/Opacity/像素回读。非默认 fit/alignment 明确拒绝；裁切和字幕等仍需组合验证。
- 许可证最多4并发、每存活 context4096个唯一 exchangeId；达到上限报告 resource.exhausted，长会话可能需要重新加载。直接 SPI 使用者须注入交换 delegate。系统能力查询或 contractVersion 不能替代解码/物理输出证据。

### 复核与修复裁定

一次新鲜只读复核后一次修复，不重审。旧 attach 失败/5秒超时可能终止新会话为 Important；许可证重定向码丢失原评 Minor，执行者按用户明确错误信息要求和冻结契约升级 Important。4个替换/卸载错误与超时测试、真实 HTTP307 经生成回调的测试及 native 错误码测试先观察失败，再修复通过。额外同 viewId 重试用例覆盖迟到成功和错误，以及当前超时仍正常上报。使用独立 attempt token，当前错误在核验归属的同一同步步骤发布，避免异步 catch 再次竞态。

复核范围裁定：授权真机播放、rotation/seek/Period/后台真实效果及截图/HDCP/外接/字幕/裁切/旋转留Task4或合成验收；Apple留3C；既有安全音频和直接 adapter 生命周期约束未变。复核者未独立运行测试，以下为执行者实际命令与 XML 证据。Pigeon Kotlin 自带新增3行尾空格，保留生成一致性，不手改生成物；其他文件 whitespace 检查通过。

### 实际验证

| 检查 | 结果 | 证据（本地 plan workspace） |
|---|---|---|
| Android JVM/Robolectric 全量 | 460发现，457通过，3既有外部 MediaMTX RTMP跳过，0失败/错误；BUILD SUCCESSFUL | `bridge-native-final.log` + JUnit XML |
| Android/SPI/主包 Dart 全量 | 289通过 | `bridge-dart-final.log` |
| Apple adapter兼容回归 | 102通过（复核前完成；后续修复仅Android） | `bridge-apple-regression.log` |
| 竞态/POST 组合定向 | 8通过，修复前对应5项失败 | `bridge-review-dart-red.log` / `bridge-review-green.log` |
| 原生 redirect码 | 修复前1失败，最终6项bridge全过 | `bridge-review-native-red.log` / `bridge-native-final.log` |
| 静态分析 | 0 issues | `bridge-analysis-final.log` |
| 公开surface、双端Pigeon | 通过；生成物对暂存版本无差异 | `bridge-pigeon-check.log` / public-surface stdout |
| 授权真机/DRM媒体 | 未运行，无媒体哈希；仍 external_missing | Task4 |

命令：JDK17 下 `packages/yl_player_android/example/android/gradlew -p packages/yl_player_android/example/android :yl_player_android:testDebugUnitTest`；`flutter test packages/yl_player_android/test packages/yl_player_platform_interface/test packages/yl_player/test`；`flutter test packages/yl_player_apple/test`；`flutter analyze` 对3包lib及3个新增/修改测试；`sh tool/check_public_surface.sh`；双端 `tool/check_pigeon.sh`。测试环境为本地 macOS + JVM/Robolectric/Flutter VM；没有把 host 单测标成真机实播。初次全量失败为旧schema fixture及插件测试过早reset Main，已修正测试；旧schema4 golden仍保留。

下一项：Apple Task3C。Task3整体和Task4保持未完成。

### Task 3B3 最终源文件 SHA-256

- `packages/yl_player/lib/src/player_controller.dart`：`efbc82a3c1e4b64fb2ce680196e81aab61c816cad9138c318361980ae44eb303`
- `packages/yl_player/lib/src/player_view.dart`：`a9f127b4e3259fc6ebe6f3d9ae3fd57d80b95c2b7421565e91a95cb1eb3af32c`
- `packages/yl_player/lib/yl_player.dart`：`6e6d5870f39e20f557dd69b8fc52e99fc724178114d20bd507d80aba19a21f37`
- `packages/yl_player/test/android_player_controller_test.dart`：`283c8e87d3eceaed14efca417b4c114ff64769fdaaf7a738f9e8746d15fc35e0`
- `packages/yl_player/test/drm_android_bridge_test.dart`：`921d611fb5220fee1399ed2916ebb491a2f9e8f5cf420be01dce17fa2ff3c602`
- `packages/yl_player/test/player_view_test.dart`：`d1523ebca609fcc55e654719db5432afb17873b8b91af552c0704ab38885e8f2`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlBoundaryValidation.kt`：`146d55d99606d848d0406ca5174083c62684362db3d954c0b9c6e23cb24047eb`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlDrmBridge.kt`：`f04543697748d61856e73a0ff25cf5f8b95439386a442727cade4502fae1c2d4`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlFailureMapper.kt`：`82bf0747a179f97e8e3a23d96b77f36be4b7b8d93cde13f6f70e794c69ac1312`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Engine.kt`：`6e28df85f440f59f650595d749863cddd80cd3a353d0eadac685170cf5e86456`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPigeonPlayerHost.kt`：`66ec8f355ef2d8a12e34fcdc3eec725523898316a3f9654e93792fed20069140`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerAndroidPlugin.kt`：`6e6af4ad7ec94dc513744b0399394e0a48c88c38e90c194881e980a57f1e060b`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlPlayerRegistry.kt`：`260b780fdb8d8f76f8bb6dc0e0edf1bb66acd5b4795a19c5d60a5eaf6c596ed4`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlProtectedViewRegistry.kt`：`1a5babde9c63c40895bbb2ba15e1b2fa63f2d990839f8f9401d1df06a2d6b1e2`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSessionCoordinator.kt`：`7f6845faf509c7c1400ce0d0b37b0fa8a3121dbfc6b00ee1d8a04b6f2f65c69d`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSessionModels.kt`：`59023f52153823b59433e7b5cfb8b9e7c91ac038b1a11522149eb8ba2302d67f`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlSourceAssessment.kt`：`bf6a17d652777a8263f5c54a953323c281c5aa81ca0ba7e07015b95590d88616`
- `packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/pigeon/YlPlayerAndroid.g.kt`：`fd7f5aa0437bfd5b374d6f8fd0c1fa058840427b79ed6c4fe135fe7cc30a8a37`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlDrmBridgeTest.kt`：`0565d248c5ea1fa0051e41a94a8339851facafda2d008dcbcc0709b3cf95c058`
- `packages/yl_player_android/android/src/test/kotlin/dev/ylplayer/yl_player_android/YlPlayerRegistryTest.kt`：`83841206605d99c860ecb1b322573138703d9134f5b968360e7f38c22012fa5b`
- `packages/yl_player_android/lib/src/android_codec.dart`：`890d70376c7a8d6017029aab19281de6f3b5f630570daae56b4454429888ce49`
- `packages/yl_player_android/lib/src/android_drm.dart`：`964283be5f50f33b4a6381ed722d7162032dc08da918a699319a8fd362496645`
- `packages/yl_player_android/lib/src/android_player.dart`：`2e60170f7edbf35fc9975b572248e03f126bbab9aedc377b9273ff3f8d9e1fc5`
- `packages/yl_player_android/lib/src/pigeon/yl_player_android.g.dart`：`1f9b8b8c1694e2e6be0804b92f8fc6d788bb8dcf512b109bc3e88c23cc0c88d9`
- `packages/yl_player_android/pigeons/yl_player_android.dart`：`18a5c3175fb425dc27626921d50e32c0e61b0572021d7b88984dd411e04515d1`
- `packages/yl_player_android/test/drm_bridge_test.dart`：`6d8e39634a165e4a5dfa5153a42f2d033debf1cc8c43bc093ad9c340aae1cf00`
- `packages/yl_player_android/test/drm_codec_test.dart`：`e48582864c53abca7336ec9b303f3323015423b6c4ad192985966334ddc3c76e`
- `packages/yl_player_android/test/support/android_fakes.dart`：`55255593b0be4a9e62db672c1400bda164f449c4ce086bd354d3ac3a8339208f`
- `packages/yl_player_android/test/yl_player_android_test.dart`：`6595fcb507d8462a7fc69fbfbeb498436b16890d313ff5543b9e1a3f6daa5f42`
- `packages/yl_player_platform_interface/lib/src/drm/drm_transport.dart`：`36187192ee95c9878eed22bd9464b2617c1b9f209f63c6199278384b617e0517`
- `packages/yl_player_platform_interface/lib/src/platform/native_video_surface.dart`：`b15b36200c37f68513cdfbde73756f723b81170eb07a9d116fdd265e228ac431`
- `packages/yl_player_platform_interface/lib/yl_player_platform_interface.dart`：`6538b38795fc453ba8c0888314ef9b553cb772e73ef5f9b436dd2ad4c86b1186`


## 2026-09-28 Task 3C1：Apple 系统密钥边界

基线 `09023d1`。本次交付独立 AVContentKeySession streaming driver 和主线程密钥状态机；**不等于完整 Apple DRM 接入**。Apple 公开 adapter 仍拒绝 DRM，schema4、普通 clear 显示路线和整包 iOS15/macOS12 下限不变，没有商业SDK。

分步裁定：现有 Apple AVPlayer 后端读像素，并复用 asset/播放器；SDK 要求在加载任何 asset key 前注册 recipient，expire 后旧 recipient 不可继续使用。因此先冻结 fresh-recipient 密钥所有权为3C1，再由3C2接独立 AVPlayerLayer、候选原子事务/音频归属、Pigeon 与 Task2 POST。代价是本阶段不能完成公共 FairPlay 播放；3C整体和CAP-DRM保持未完成。

实现：证书/内容ID输入限额、SPC≤1MiB/CKC≤4MiB、总期限含系统确认、4并发与4096请求上限、重复回调合并、epoch/request匹配、迟到响应隔离、更新撤回可用状态、停止/后台/销毁清理。CKC安装返回不代表可用，须当前系统请求成功；过期只取明确expired-lease证据，普通HTTP错误不推断过期。系统重试关闭，POST重试政策仍归Task2；不获取证书、不猜skd映射、不存离线密钥、不上传session报告。清理保持主线程，配置清除不保证SDK所有副本物理抹除。

系统fake测试是必要替身：本机没有授权FPS证书/内容/CKC服务，不触发真实授权解密。真实系统driver经两端SDK编译；mock的.protection事件不证明系统已检测到安全decoder/HDCP，isUsable也不是输出保护结论。

### 复核与验证

一次只读复核：无Critical/Minor，1个Important（取消码在safe diagnostics被简化）；执行者另发现清理过程中可重入读取到旧isUsable。两项在 `fairplay-review-red.log` 先观察失败，一次修复后双端定向回归通过，不重审。初始API缺失RED见 `fairplay-key-red.log`；旧recipient复用/所有者释放泄漏的行为RED见 `fairplay-lifecycle-red.log`，修复后10项通过，再扩展至14项。

| 验证 | 实际结果 | 证据（本地plan workspace） |
|---|---|---|
| macOS全量原生（复核前） | 561发现/通过，0跳过/失败；实际身份核对通过 | `fairplay-macos-all.log`、`fairplay-macos-runtime/case-identities.json` |
| macOS最终定向 | 32通过：14项FairPlay + 会话/诊断/AVPlayer元数据 | `fairplay-macos-final.log`、对应`final-runtime` |
| iOS最终定向 | 32通过，0跳过/失败；实际身份核对通过 | `fairplay-ios-final.log`、对应`final-runtime` |
| iOS完整复验 | stdout逐项匹配647发现：644通过/3跳过/0失败；收尾停滞，完整xcresult gate未完成 | `fairplay-ios-full-final.log`、`fairplay-ios-full-stdout-identities.json` |
| 测试发现/迁移/公开surface | 双端PBX成员/三份源码哈希一致；迁移工具4项通过；public-surface通过 | `main_example_tests.py --current-only`、`test_main_example_migration.py`、`check_public_surface.sh` |
| Dart/Pigeon | 本阶段没有Dart/wire/schema变化，未重复运行 | git差异范围 |
| 授权真机解密/显示保护 | 未运行，媒体哈希无；external_missing | Task4 |

首次iOS完整运行未能正常结束：测试进程退出后xcodebuild空闲超过5分钟，testmanager日志证实进程退出；SIGINT未结束且输出内部DVTOperation诊断，SIGTERM终止自有命令（143）。该次不计通过；保留`fairplay-ios-all.log`、部分xcresult和`fairplay-ios-testmanager.log`。之后双端32项定向成功，iOS完整复验开启60秒默认/120秒最大单例时限，记录详细测试事件。第二次完整运行的647个stdout身份与当前canonical清单精确一致（644通过/3跳过），但All tests完成后Xcode再次空闲超过2分钟且结果包仍停留Staging；采样保留在`fairplay-ios-xcode-sample.txt`，终止自有命令（143）。因此仅声明用例日志结果，不声明iOS完整xcresult gate通过；硬件跳过的结果包附件也未完成核验。最终双端32项定向xcresult正常生成、身份检查通过。没有用生产代码变更掩盖测试收尾问题。

命令：`xcodebuild test CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES -workspace packages/yl_player/example/<platform>/Runner.xcworkspace -scheme Runner -parallel-testing-enabled NO -derivedDataPath packages/yl_player/example/build/native-<platform>-tests`，macOS SDK/destination为macosx/本机，iOS为iphonesimulator/iPhone18Pro模拟器；定向使用 YlFairPlayKeySessionTests、YlObservabilityBoundaryTests、YlAppleSessionTests、YlAvPlayerNonblockingMetadataTests 四组。macOS27.0(26A428)/arm64，iOS27模拟器；Xcode27 SDK对既有XCTest低部署下限及既有Sendable测试有警告，不修改产品最低系统以规避。结果按xcresult实际身份解析，源码中的平台条件计数不当作实际执行数量。

复核放在后续阶段的项目及裁定：Task2 POST凭据/重定向未动；外层身份认证、候选回滚、fresh asset生产调用顺序和protected view接入属于3C2；实际secure decoder/HDCP/外接、授权rotation/seek/Period/后台及字幕/几何仍需Task4/P02/P07。审查者未运行测试，以上为执行者实际结果。下一项3C2必须在解绑AVPlayer/AVPlayerLayer后expire，恢复创建新asset，并继续逐源严格策略检查，不能把本阶段成功标记当作输出安全证明。

### Task 3C1 最终源文件 SHA-256

- `packages/yl_player/example/ios/Runner.xcodeproj/project.pbxproj`：`fb686bfc0cb162a55f54bbcb6dbe684ecfc34d185b22294832aa646482393393`
- `packages/yl_player/example/ios/RunnerTests/YlFairPlayKeySessionTests.swift`：`fc87637164c690bb7c0bf8c85a0146023958b6e475b89a838e82cad959981726`
- `packages/yl_player/example/macos/Runner.xcodeproj/project.pbxproj`：`9fcf2404cb6a3e7aadd5dbd497b4b3ccd015c0506c45b721bc9ec5e0e786c087`
- `packages/yl_player/example/macos/RunnerTests/YlFairPlayKeySessionTests.swift`：`fc87637164c690bb7c0bf8c85a0146023958b6e475b89a838e82cad959981726`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DRM/YlFairPlayDriver.swift`：`4422effd4d350b52aca727cf123ffa5eac936f965a93461e7d653a7623f410ba`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DRM/YlFairPlayFailure.swift`：`7d1d48b9516c82779d0e4b6e1cdf3454df593d645a515b5fbeaa2c1e2d1b064e`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DRM/YlFairPlayKeySession.swift`：`89e7c3822bd65d02c68667e082320aae8e1c2aaeb2290cb4c3e1cb963e64c0c5`
- `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/Diagnostics/YlAppleSafeDiagnostics.swift`：`9060a1decda224d8bfd716b633d9f745bb4a216d3ca98a58c81ef9cf457e50b1`
- `tool/consumer_fixtures/apple_flutter/RunnerTests/YlFairPlayKeySessionTests.swift`：`fc87637164c690bb7c0bf8c85a0146023958b6e475b89a838e82cad959981726`
- `tool/consumer_fixtures/apple_flutter/main_example_tests.py`：`9ef77a64c2189c56c49ef28f4286a58650faeb6529b66dbcf0aec0ab513c67b1`
- `tool/consumer_fixtures/apple_flutter/new-tests-manifest.json`：`d1b04af79b8f6098df1119749c677bd28e4ab44d8ea3d01f9424d0a07bf610f5`
