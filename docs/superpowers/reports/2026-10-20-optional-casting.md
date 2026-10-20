# 可选投屏实现与验证记录

日期：2026-10-20。实现基线：`3433d03f`。本次未 commit、push 或发布包。

## 实现结果

- 新增可选 `yl_player_cast`，workspace 注册包及独立 Android/iOS/macOS 示例；播放器不反向依赖投屏包。
- DLNA：IPv4 SSDP 发现、UUID 去重/过期、设备/SCPD/ConnectionManager 能力、SOAP AVTransport/RenderingControl、状态轮询及退避、进度和音量控制。
- 控制器：命令串行、取消代次、显式本地交接与恢复、AirPlay 冲突、会话身份保护、资源释放。统一 AirPlay 入口直接位于控制器，无额外 `airplay.dart` 文件。
- Apple：新增可选媒体交付 SPI、独立通道与租约，复用 RTMP/RTMPS/HTTP-FLV H.264/AAC → HLS/fMP4 生产器，不启动隐藏 AVPlayer。
- Android：扫描与会话引用计数组播锁、引擎解绑清理和所需 manifest 权限。
- 中文设计、计划、包说明、示例与验证记录已落盘。Google Cast 不在实现范围内。

## 自动验证

| 检查 | 结果 |
| --- | --- |
| 投屏包测试 | 最终串行复测 47 项通过 |
| 受影响四包 Dart 全量 | 并行首跑 2022 通过、8 失败；详见下文 |
| 失败文件及完整投屏包串行复测 | 157 项通过、0 失败 |
| 四包及示例静态分析 | 无问题；最后的控制器修改另做投屏包复查 |
| 公共 API 边界检查 | 通过 |
| iOS 原有 AirPlay/RTMP(S) 原生回归 | 73 通过、0 失败、0 跳过 |
| macOS 原有 AirPlay/RTMP(S) 原生回归 | 73 通过、0 失败、0 跳过 |
| Apple HTTP 服务测试 | 45 项通过 |
| Apple 独立媒体交付原生测试 | 生命周期、取消、替换、失败、接口变化、策略拒绝均通过 |
| 独立直播真实 HTTP 拉取 | playlist/init/segment、Range、HEAD 均通过；释放后服务不可访问 |
| 旧 VOD remux/HLS 解码 | 出帧回归通过 |
| Android 原生组播插件 | assembleDebug 通过 |
| Android 完整示例 | debug APK 构建通过 |
| macOS 完整示例 | debug app 构建通过 |
| iOS 完整示例 | arm64 Simulator、无签名构建通过 |

首轮全量测试与 Xcode 编译并行运行：6 项既有网络时限/一致性测试、1 项 128 设备发现时限测试失败，另 1 项新增 AirPlay 取消测试在测试运行期间加入，与先前编译的控制器代码不一致。停止修改并结束本次原生编译后，使用 `--concurrency=1` 对所有失败文件及完整投屏包重新编译、复测，157 项全部通过。没有修改既有网络测试或放宽其超时断言；首轮全量运行不是一次无失败运行。

当前工具链的 `lipo <binary> -verify_arch arm64 x86_64` 返回“requires exactly one input file”，但单独 arm64 校验正常，因此普通 Flutter 通用模拟器构建未通过。随后使用 `xcodebuild ... ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO` 完成完整 iOS 示例构建，未收窄项目的架构设置。Swift 编译仍有已有的 Sendable、optional 和弃用 API 等警告。

## 复审与修复

独立复审的 P2 均已关闭，复查无遗留 P1/P2：

- 仅清理由统一入口创建且仍为当前身份的 AirPlay 会话，取消后的迟到加载同样清理。
- 取消排队的发现，不让停止后扫描重新启动。
- 在评估阶段拒绝不具备媒体交付 SPI 的后端。
- Stop 失败仍释放资源并清空公开会话；detach 能力来自实际会话。
- 直播交付提前拒绝 managed 网络策略及显式格式冲突；拒绝不取消已有合法准备。
- 严格校验 SOAP Envelope/Body、服务 namespace 与匹配 ActionResponse，普通 XML 200 不算加载确认。
- 限制重复 SCPD 请求，提前拒绝不支持的初始 seek。

## 验收边界

- 未连接真实 DLNA 电视或 AirPlay 接收端；真实发现、解码兼容、首帧、长时间播放、后台和网络切换仍待设备验收。
- Apple 自定义直播要求接收端明确声明 HLS，并由宿主登记已验证 HLS/fMP4 的设备 UUID；不是所有 DLNA 电视都能使用。
- Android 仅提供设备可拉取的 HTTP(S) 直连，不提供 RTMP/RTMPS/HTTP-FLV → HLS 转换。
- iOS SSDP multicast entitlement 必须由宿主取得 Apple 授权并使用匹配的签名配置。
- 托管直播不能断开控制后继续播放；停止、销毁或交付失败释放 HTTP 服务与生产器。
- 未完全拆除播放器核心内原生 AirPlay 二进制；旧 API 保持兼容。

## 后续五项优化验收

用户要求全部优化后，已完成：

1. 返回本地在 Stop 完成后复核取消代次、销毁、AirPlay 和本地身份；取消后的晚到恢复按身份清理。四类 Stop 等待竞态测试先复现失败，修复后通过，并覆盖本地加载阶段的取消和销毁。
2. Apple 交付增加无副作用的原生 `admit`，与 `prepare` 共享校验。拒绝新请求保留原准备与租约；合法替换才取消旧准备；准入队列有界。
3. SSDP 对相同 UUID 的 LOCATION 变化重新读取描述，隔离旧响应，保留 8 个作业和 128 个设备的边界。
4. provider/controller 统一公开发现状态和异步错误；会话快照提供有效能力。示例展示搜索/失败状态，按暂停能力、连接和路由冲突启用控件。
5. SOAP 发送准确的 UTF-8 Content-Length，非 ASCII 元数据回归确认不使用 chunked。

本轮集中验证（串行单 worker）：**223 项全部通过**，其中投屏包 64 项、示例 2 项、Apple 包 155 项、核心交付接口 2 项。投屏包（含示例）及 Apple 包静态分析无问题；公共 API 边界与 `git diff --check` 通过。

原生使用生产 Swift 源码执行共享通道/host 准入测试，确认 managed 策略、位置、尺寸、缓冲和格式拒绝码一致且不会影响已有资源；合法替换、取消、失败、销毁、接口变化全部通过。实际 HTTP-FLV → HLS 拉取验证 playlist/init/segment、Range、HEAD 和释放后源站关闭。原生编译存在已有 Swift 警告。本轮未重复三平台示例构建和原有各 73 项 AirPlay 回归，上方结果属于初次实现验收。

DLNA 测试夹具的请求/等待时限已适当放宽，避免并发编译负载导致误报；过期测试改为先完成发现再发送 1 秒续租广告，明确验证过期行为。生产默认超时和扫描窗口没有放宽。

独立只读复审覆盖上述五项实现和回归测试，未发现可证明的 P1/P2。真机验收边界保持不变；本次仍未 commit。

## 本机会话证据

日志在本机临时目录，不作为可移植测试输入：

- `/tmp/yl-cast-final-tests.log`：四包全量首跑。
- `/tmp/yl-cast-recheck-tests.log`：最终串行 157 项复测。
- `/tmp/yl-cast-final-analyze.log`、`/tmp/yl-cast-last-analyze.log`：静态分析。
- `/tmp/yl-delivery-rtmp-ios-summary.json`、`/tmp/yl-delivery-rtmp-macos-summary.json`：原生各 73 项结果。
- `/tmp/yl-delivery-admission-green.log`：独立资源与实际 HLS 拉取。
- `/tmp/yl-cast-ios-build.log`：通用模拟器工具链失败诊断。
- `/tmp/yl-cast-ios-arm64-build.log`：arm64 模拟器构建成功。
- `/tmp/yl-cast-optimizations-tests.log`：本轮 223 项集中验证。
- `/tmp/yl-delivery-review-native-green.log`：本轮原生准入、生命周期和真实 HLS 拉取。

独立原生交付回归入口：`python3 tool/airplay/run_media_delivery_tests.py`。
