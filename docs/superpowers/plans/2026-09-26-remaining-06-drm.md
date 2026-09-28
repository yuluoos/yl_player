# P06 Widevine / FairPlay 与受保护输出 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行执行方式；本计划不自动启动子代理。

**Goal:** 建立平台对应的 DRM 配置、许可证生命周期和受保护显示，取得授权资源后完成真实设备播放验收。

**Architecture:** Android 使用系统 Widevine + Media3，Apple 使用 HLS + 系统 FairPlay。先验证安全 surface/native view 路线，再扩展 source/bridge 契约；不将受保护视频走解密像素回读，不承诺跨平台播放同一加密 MPD。

**Tech Stack:** MediaDrm/Media3、AVContentKeySession/AVPlayer 原生显示候选、Flutter platform view、Dart/Pigeon、受控许可证测试服务。

**Spec:** [需求基线 v2.2](../specs/2026-09-20-playback-expansion-requirements.md)、[架构入口](2026-09-22-playback-feasibility.md)、[执行总览](2026-09-26-remaining-overview.md)。

**起点：** `5409313`；P06 Task 1 可行性原型已执行；后续生产 DRM 尚未实现。此后执行前重新记录 HEAD 和工作区，不能覆盖后来改动。

## Global Constraints

- Android API 24、iOS 15、macOS 12；能力自身可限定版本，不能提高整个包部署下限。
- 使用系统 API 与开源方案，不接入商业 SDK；保留已有 Apple 音频/FEL 和 Player/Session 行为。
- managed 请求、跨域凭据过滤、取消/重试预算必须实际执行；不能执行的严格策略明确拒绝。
- buffer.bounded 不是提示；hardwareRequired 需要实际解码器证据。不得静默软解、降低固定档位或放宽 HDR/Dolby 约束。
- PD-01 已确认：下一 Period 缺固定档位时回到自动，仍受独立上限约束。PD-02/03 尚未确认，只阻塞各自依赖步骤。
- 错误保留 code/category/scope/retryable/diagnosticId；不泄漏地址、请求头、许可证、脚本任意文本或原生堆栈。
- 先测基线再冻结优化目标。模拟器、受控服务、mock 与真实设备/授权资源证据分开；跳过不计通过。

## Review Focus

- 许可证 POST 重试/重定向：不能套媒体 GET 许可或泄漏凭据（任务 2）。
- 候选失败/取消后的迟到密钥：不得影响当前播放（任务 3）。
- 保护等级/安全解码器不足：不能降为不受保护输出骗过验收（任务 1/3）。
- 密钥轮换、后台恢复、seek/跨段：真实授权生命周期需真机证据（任务 3/4）。
- 受保护视频上的字幕/几何/外接：不依赖像素读取，分别验证保护和画面（任务 1/4）。

---

## 范围与依赖

当前没有完整 DRM 公开配置和授权播放证据。用户暂无授权流和许可证服务，不要求用户先提供资源才能做工程工作；资源只阻塞真实受保护播放结论。不得把 mock license、明文内容或模拟器结果记为 CAP-DRM 通过。

任务 1/2 可尽早执行。字幕叠层接 P02，已支持 clear 路径需保持；Android API24 与更高版本的加密模式能力分行，不抬高整个包下限。本轮不追加离线下载/永久许可证产品功能。

## 文件与接口

- 公共：`packages/yl_player_platform_interface/lib/src/source/media_source.dart`、`http_request.dart`、`model/source_assessment.dart`、`capabilities.dart`、`failure.dart`、`platform/native_video_surface.dart`；`packages/yl_player/lib/src/playback_session.dart`。
- 双端 Pigeon：`packages/yl_player_android/pigeons/yl_player_android.dart`、`packages/yl_player_apple/pigeons/yl_player_apple.dart`。
- Android：`packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Core.kt`、`YlMedia3Engine.kt`、`YlPlayerRegistry.kt`、`YlPlayerErrorPolicy.kt`。
- Apple：`packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Engines/AvPlayer/YlAvPlayerBackend.swift`、`Shared/Session/YlOpenCoordinator.swift`、`iOS/YlIosVideoView.swift`、`macOS/YlMacosVideoView.swift`。
- 新建：`docs/superpowers/specs/2026-09-26-drm-contract.md`；`docs/superpowers/reports/2026-09-26-remaining-06-drm.md`；`packages/yl_player/example/integration_test/drm_lifecycle_test.dart`。

Dart DRM 配置类型已在 Task 2 冻结，生产受保护视图类型仍待 Task 3 实现。任务 1 产出保护能力/视图契约，任务 2 产出精确 Dart 配置/许可证传输；原生配置和回调桥接随任务 3 的原子会话实现；后续实现只能消费这份契约。许可证请求对象必须与媒体请求策略分开，不能复用一个无法表达 POST/body/idempotency 的 GET 配置。

### Task 1：受保护显示可行性与架构决定

- [x] 从实际 Flutter view/texture 入口跟踪当前输出，记录像素回读、截图、旋转、裁切、字幕层及外接路径；对安全 SurfaceView/native AVPlayer 显示做最小原型。
- [x] 查询执行时官方文档及本地 SDK/依赖版本，冻结支持的保护/加密模式/最低能力 OS；只用系统及开源路径，不升级整包系统下限以避开问题。
- [x] 用 clear fixture 先验证原生 view 生命周期、尺寸、首帧关联、多个播放器和释放；这些测试通过仅证明 view 布线。真实安全保护仍需授权内容和物理设备。
- [x] 输出架构决定：所选路径、精确 view/bridge 类型、保护能力如何报告、拒绝条件、字幕接入面、不能满足的范围及替代候选。若缺资源无法证明保护，把该门槛保持未通过，同时继续可独立测试的 Task 2。
- [x] 提交可行性原型/报告；不把 prototype 默认切换为所有媒体生产路径。

### Task 2：DRM 契约及许可证请求边界

- [x] 在 DRM spec 定义 Widevine/FairPlay 的配置结构、证书/内容标识获取、请求/响应格式、取消 token、期限、密钥更新、错误码和隐私边界。二进制响应与安全标识不得通过 `toString` 或普通诊断透传。
- [x] 公共合约与现有桥接拒绝路径先写失败测试：缺配置、scheme 与平台不匹配、旧适配器、不支持加密模式、过大 body、无证据过期、HTTP403、timeout、取消迟到回包。
- [x] 用本地受控 HTTP 记录器验证 POST 的真实请求次数和凭据流向；默认不因网络错误重发不可证明可重试的许可证 POST。示例测试预期不是生产返回值：

```text
case: license-http-403
observed_status: 403
public_meaning: license_denied
must_not_claim: license_expired
repeat_same_request_without_policy: false
public_payload_contains_body_or_key: false
```

- [x] 实现最小配置/验证、限额、显式重试许可与错误映射；先将 ERR-07 正式码表写进 spec 和 `failure.dart`，再在 native mapper 使用同一值。
- [x] 跑合约/HTTP/双端 Pigeon check，提交公开配置与受控许可证传输；报告明确“尚无真实解密播放结论”。

### Task 3：系统密钥与会话生命周期

2026-09-27 开始按平台分步交付，2026-09-28 **Task 3 工程集成完成，授权物理验收留在Task4**：

- [x] 3A：Android 内部 MediaDrm driver、密钥代际/取消/更新/后台恢复边界和系统 fake 测试；当前未接生产播放器。
- [x] 3B：Android 受保护输出与 Media3 candidate 原子事务、Pigeon challenge/response 和 Task 2 传输连接；验证 clear 回归。
  - [x] 3B1：内部 Media3 DrmSessionManager/DrmSession 消费 3A 密钥状态，管理 decoder 引用、CryptoConfig 与安全 decoder 查询；不开放生产准入。
  - [x] 3B2：原生受保护 view 注册/attach/detach、secure candidate output、内部 Media3 route、实际 decoder/key 门槛与原子替换/回滚；Dart provider 和正式 ACK wire 留在 3B3。
  - [x] 3B3：Pigeon challenge/response、受保护 view ACK 与 Task 2 许可证传输连接，完成组合回归后才开放对应准入。
- [x] 3C：Apple AVContentKeySession、AVPlayerLayer 与候选事务/同一桥接，验证原生状态机和 clear 回归。
  - [x] 3C1：AVContentKeySession streaming driver、SPC/CKC 交换边界、确认/更新/取消/期限与 fresh-recipient 生命周期；原生 fake 回归，不开放公共准入。
  - [x] 3C2：独立 AVPlayerLayer 生产输出、候选原子事务/音频归属、Pigeon 与 Task2 连接及逐源准入；禁止接入现有像素读取路径。

以下完整验收要求仍逐项保留，不能用 3A 的内部测试替代生产集成：

- [x] 随原子会话实现生产受保护 view 描述符、attach/detach/ACK 与 challenge/response Pigeon 桥接（从 Task 2 移入）；不得用 schema4 丢弃配置后继续 clear 播放。

- [x] 依 Task 1 选定路径接 MediaDrm/AVContentKeySession；测试 load 候选失败回滚、stop/dispose、replacement、后台恢复、更新/rotation。密钥回调使用会话代际且严格限制资源生命周期。
- [x] 先以系统边界 fake 驱动状态机失败/成功/取消，断言过期需明确系统/许可证证据，普通 HTTP 错误不能推断过期。
- [x] 实现系统事件→同一 `YlFailure`/session 状态映射、命令 ACK 和资源清理；保护不足、secure decoder 不可用时明确拒绝，不切非保护 surface 或基础画质。
- [x] 跑原生状态机及 clear-path 回归，保证增加 DRM 不破坏普通 DASH/HLS、音频所有权或严格策略。
- [x] 提交按平台分开的生命周期实现；mock 结果与真机结果分表。

### Task 4：授权资源与真实设备验收

- [ ] 创建私有验收资源表：Android DASH URL/Widevine 服务及必要请求配置，Apple HLS URL/FairPlay 应用证书与许可证服务，授权使用范围/有效期、拒绝/失效/更新用例、设备/保护输出条件。仓库只保存不含秘密的样本标识和哈希。
- [ ] 在资源可用后运行 `drm_lifecycle_test.dart`，覆盖首次播放、seek、跨段、切轨、密钥更新、拒绝/超时/过期、断网恢复、后台恢复和取消。不得从 DRM 截图/像素探针判断成功；用允许的系统状态、实际显示观察和播放进度证据。
- [ ] 与 P02 验证字幕和画面几何，与 P07 分开验证外接保护/信号；同内容不同平台 delivery 的时间轴应一致。
- [ ] 缺资源时输出实际仍缺的输入与受影响行，不伪造通过，不暂停其他计划。已确认范围无法成立时提交技术依据与产品取舍项。
- [ ] 三平台相关授权行都通过后才能在 P08 最终报告声明 CAP-DRM 完成；提交真实验收报告。

## 交付与检查

- [ ] 按任务提交可独立验收的改动；每次提交只包含该任务源文件、夹具、必要生成物及报告，不使用无选择的整仓暂存。
- [ ] 在本计划指定的报告中记录基线提交、最终源文件 SHA-256、媒体哈希、设备/OS、命令、真实结果身份、失败和跳过；修复后仅重测受影响范围。
- [ ] 执行总览中的对应检查入口；新测试必须进入测试发现清单，不能只创建文件而没有运行。代码步骤先观察新增行为测试失败，再实现并通过。
- [ ] 对照本计划五项 Review Focus 和需求矩阵复核；只把实际通过的子行写进 `docs/platform-support.md`。仍缺输入的行保留具体解除条件。
- [ ] 更新总览的实施/验证状态。没有完整实现及实际验收时，不将整个 CAP 标为完成。

2026-09-27 Task 1 已完成 clear 内容的三端 Debug 原型与架构决定，详见执行报告；Task 2 已完成 Dart 配置、受控许可证 POST 与旧适配器拒绝；原生桥接随 Task 3 实现。Task 3/4 仍未完成，Task 1/2 通过不代表真实受保护播放通过。

2026-09-28 Task 3B3 已完成 Android schema5 许可证/取消桥接、保护视图描述符和 ACK、控制器传输与 hybrid view 接入；3B 工程集成完成，下一项为 Apple 3C。Android API29+ 仍逐源检查系统密钥、安全 decoder 和输出，授权真机验收保留在 Task4；上方跨平台验收项继续未勾选。

2026-09-28 Task3C1 系统密钥阶段完成，双端最终各32项定向回归通过，macOS复核前全量561项通过。iOS完整复验stdout644通过/3跳过，但Xcode收尾停滞，完整xcresult gate未完成，报告保留该限制。下一项3C2生产AVPlayerLayer/候选/桥接；3C整体、授权物理验收和CAP-DRM不勾选。


2026-09-28 Task3C2 工程集成完成：Apple 独立AVPlayerLayer、FairPlay候选/音频事务、schema5许可证与受保护view ACK、Task2真实POST组合已接通。最终macOS完整571项、iOS定向40项及普通媒体202项、Dart203项通过；测试身份/哈希、Pigeon和公开surface检查通过。独立复审两项重要竞态及自检暂停状态问题均修复。iOS本次仅定向覆盖242项，未声明完整suite；此前完整xcresult收尾限制保留。下一项Task4仍缺授权资源，CAP-DRM不勾选；不得将工程测试当作真实解密/HDCP/物理输出验收。
