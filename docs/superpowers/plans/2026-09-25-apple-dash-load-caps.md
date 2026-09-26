# Apple DASH load caps Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development. 用户已明确授权继续执行；保留当前工作区 `codex/fel-integration`，基线 `d1b5b65`。本阶段不自动 commit/push，原生及设备构建串行。

**Goal:** Apple DASH 每个 Period 的加载时视频上限实际约束候选和输出，并明确拒绝无法执行的运行时变化。

**Architecture:** 原始节目严格验证 → 每 Period 约束交集过滤 → 现有完整自动路径；不可变 Load 策略贯穿 loader、恢复与像素输出。

**Tech Stack:** 既有 Swift/AVFoundation、Flutter/Dart，无新依赖。

**Spec:** `docs/superpowers/specs/2026-09-25-apple-dash-load-caps-design.md`

## Global Constraints

- iOS15/macOS12；Apple schema3/Android schema4/SPI2不变，无固定选轨 wire/API 改动，无商业 SDK。
- 上限仅初次 Load 生效；同值幂等，不同值含清空以 `policy.video_constraints_reload_required` 拒绝且不保留意图。
- width/height/declared video bandwidth 独立交集；每个 Period 不能为空，禁止越限最小档兜底。
- 有约束时原始节目所有视频须通过保守变化家族验证，union16；无约束旧行为保持。
- 原 MPD2MiB、depth64、Period64、Representation256、segments100000、URI8192/累计4194304、playlist2MiB/registry4MiB 不变；凭据剥离不能恢复。
- 任何像素返回/发布前校验实际显示尺寸，超限不发该帧/firstFrame；失败仅安全固定消息。
- 不更改普通 HLS/MP4 控制语义，不声明完成 runtime caps/fixed/fullABR。

## Review Focus

1. 第二 Period 没有低档：整 Load 在 URL emission 前失败，不部分播放或越限。
2. 同值、清空、恢复中变更：拒绝不能污染 accepted constraints/恢复清单，nil legacy options 要捕获继承值。
3. 不可信清单尺寸：真实高分辨率帧不能经 copyPixelBuffer 或 native texture 出口绕过限制。
4. 高档位不兼容但被过滤：不能借过滤隐藏原始未知codec/range/SAR或打破预算/凭据。
5. 候选失败/取消与 Stop：旧会话继续，停机后不能再发布候选或保留旧限制。

## Task 1: Native enforcement and safe errors

**Files:** `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/DASH/YlDashHlsCompiler.swift`（必要紧凑policy文件）、`Shared/HLS/YlHlsResourceLoader.swift`、`Shared/Session/YlAppleSessionCoordinator.swift`、`Engines/AvPlayer/YlAvPlayerBackend.swift`、`Shared/Diagnostics/YlAppleSafeDiagnostics.swift`；`packages/yl_player_platform_interface/lib/src/model/failure.dart` 与 `src/diagnostics/safe_diagnostics.dart`。必要最小 session/source model 调整须在报告解释。测试延伸 canonical `YlDashHlsCompilerTests.swift`、`YlDashResourceLoaderTests.swift`、`AppleHostCharacterizations.swift`/现有相应 session/geometry tests 及镜像/current-only inventory；Dart safe diagnostics tests。

**Interfaces:** compile 增加 `videoConstraints: YlAppleVideoConstraints = .unconstrained`；prepared asset / loader 相同默认内部参数；公开 Load options 与 setVideoConstraints 形状不变。新增固定 code `policy.video_constraints_reload_required`，现有质量 code `decoder.quality_constraint_unsupported` 保留并提供安全说明。

- [x] 添加失败回归：低档交集与码率边界、empty next Period零emission、原始不兼容高档拒绝、unchanged无约束/预算/凭据。先记录代表性新正例 RED。
```swift
// compile(..., videoConstraints: .init(maxWidth: 320, maxHeight: 180, maxBitrate: 350000))
// every video path uses low init/chunks in BOTH Periods; bandwidth master retains audio.
// high-only next Period => decoder.quality_constraint_unsupported; both URL counters == 0.
```
- [x] 实现原始严格验证、过滤与原规划；把不可变约束传至 Load/恢复，所有条件失败先于媒体 emission。安全语义错误不可被 compiler blanket catch 降为 generic container，也不可转发任意 error 原文。
- [x] 在 backend 命令变更前和 coordinator intent 保留前拒绝不同约束；相同幂等，Stop、新 Load、失败候选和恢复覆盖。禁止引入不完整运行时 item swap。
```swift
// Same tuple -> success. Changed/cleared tuple -> reload-required before assignment.
// Failed/cancelled new Load leaves old accepted tuple and playback identity intact.
```
- [x] 在实际像素出口检查尺寸，所有超限帧被抑制、首次帧信号不发，主线程发布安全失败且 generation fence 生效。用真实 CVPixelBuffer 和现有 texture seam 验证，不能只测试一个不接入输出的纯 helper。
- [x] 明确 Dart 安全消息及白名单回归；相关 Dart目标测试、compiler/loader 与新 session/output原生测试两平台串行GREEN。记录精确测试选择/数量，不重复不相关大套。同步 canonical mirrors/current manifest，历史不变。
- [x] 独立任务复审；交接 public runtime 所需行为/错误/证据，不提交。

## Task 2: Public playback acceptance and durable documentation

**Files:** `packages/yl_player/example/integration_test/apple_dash_load_caps_test.dart`，必要 `support/dash_server.dart`仅测试选项；现有dash_variants真实字节复用。新docs报告 `docs/superpowers/reports/2026-09-25-apple-dash-load-caps.md`、`docs/platform-support.md`。root更新架构入口/计划/ledger。

**Interfaces:** `DashServer.start(variants:true, manifestOverride:...)`；Load options 的 YlVideoConstraints 与现有 session.setVideoConstraints；所有观察绑定 session.id。

- [x] 写 spec 四个公开用例：cap320×180/350000跨两段+双向seek；失败新Load保留旧；同值成功/改值和清空拒绝+新Load可改变；低声明高字节首次帧抑制。夹具内存清单可复用已有高低MPD，无需新媒体。检查自动模式和initial reason。
```dart
// await player.load(source, options: YlLoadOptions(videoConstraints: ...));
// seek5: 5.5s < sampledPosition < 8s; seek1: 1.5s < sampledPosition < 4s.
// Do not infer no high output from low metadata alone; assert real geometry + media requests.
// Lying MPD: session failure quality code, no matching-session firstFrame.
```
- [x] macOS/iOS单文件各4例串行；最终log记录采样位置/geometry/请求，无错误URL/头输出。针对Dart analyze、资产校验、diffcheck；自有模拟器及四个Fluttertarget恢复。
- [x] 报告精确原生和公开证据/OS/警告；说明declared video bitrate非网络限速，有约束保守子集，运行中改值需要新Load，固定/运行时事务仍后续。记录已提交基线d1b5b65与本阶段未提交状态。
- [x] 独立任务复审与修复复审通过；保留证据不自动提交。
- [x] 最终整阶段复审与一次修复复审通过，无未解决发现；验收报告记录分批证据，改动保留待提交。
