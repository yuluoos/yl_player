# Apple 音频最终尾部候选接入 Implementation Plan

当前状态（2026-10-10）：R5本机完整回归与独立短/长门禁已完成，详见[最新显示调度及验收记录](../reports/2026-10-10-display-cadence-latency.md)。首次激活阻塞主线程的触发路径已定位，见[新根因记录](../reports/2026-10-10-display-activation-root-cause.md)；激活卡顿的渲染修复、A5整体资源边界和R4设备/物理输出格仍开放。下文按阶段保留历史执行结果，不把后续通过回填为早期失败已修复。

后续Profile/AOT也复现活动12帧丢弃（激活请求前1、后11），见[对照记录](../reports/2026-10-10-display-profile-activation.md)。用户已同意macOS14+内部定时显示候选设计；渲染修复转入[五项执行计划](2026-10-10-macos-timed-presentation.md)，默认开关与资源准入不变。


> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行执行方式；本计划不自动启动子代理。

**Goal:** 将已验证的工具策略接入默认关闭的 macOS 本地有限点播测试路径，验证真实 renderer、账本、媒体时钟和控制操作，形成可审计的生产准入结论。

**Architecture:** 普通 PCM 按真实 rendered 通知退还本所有者资源，保留一块计费的真实尾部，EOF 由尾部 playedBack 表示最终播放边界。复用转换器已有 reservation，分开资源数量、已提交时间范围与输出排空；100ms 连续尾部等待触发单向兼容回退。生产默认继续使用逐缓冲 playedBack，直到独立验收完成。

**Tech Stack:** Swift、AVFAudio、现有 FFmpeg bridge、XCTest、Python unittest；macOS 原生消费工程与镜像夹具。

**Spec:** [输出完成契约 §10](../specs/2026-10-08-audio-output-completion-contract.md)、[需求基线](../specs/2026-09-20-playback-expansion-requirements.md)、[P08](2026-09-26-remaining-08-performance-release.md)。

最新状态（2026-10-10）：唯一最终复审P2暂停锚点覆盖问题已修正，相关67/67、最终macOS674/674、iPhone18 Pro Max 676通过/3条件跳过，独立30.031s无探针短播通过。但同身份long在55s采样时已有9帧丢弃/199.375ms最大落后，后续一次有界时序诊断复现1帧；根因尚未证明，R5及当前任务线未全部完成。资源A5与外部设备格继续开放，候选关闭。以下历史记录保留原状态，以末尾R5和当前准入矩阵为准。

起点 `9c5967a`。Task 1–5 已实现并执行验证；资源采样帧断言失败如实保留，默认准入仍关闭。既有工具通过不能替代生产验收。

## Global Constraints

- Android API 24、iOS 15、macOS 12；能力自身可限定版本，不能提高整个包部署下限。
- 使用系统 API 与开源方案，不接入商业 SDK；保留已有 Apple 音频/FEL 和 Player/Session 行为。
- managed 请求、跨域凭据过滤、取消/重试预算必须实际执行；不能执行的严格策略明确拒绝。
- buffer.bounded 不是提示；hardwareRequired 需要实际解码器证据。不得静默软解、降低固定档位或放宽 HDR/Dolby 约束。
- PD-01 已确认：下一 Period 缺固定档位时回到自动，仍受独立上限约束。PD-02/03 尚未确认，只阻塞各自依赖步骤。
- 错误保留 code/category/scope/retryable/diagnosticId；不泄漏地址、请求头、许可证、脚本任意文本或原生堆栈。
- 先测基线再冻结优化目标。模拟器、受控服务、mock 与真实设备/授权资源证据分开；跳过不计通过。
- 候选只接收内部显式注入、macOS managed fallback、本地有限且可 seek 的非直播输入；初始 rate=1、AAC、实际 PCM 为 48kHz/双声道/Float32 planar、每块 1…1024 帧。AAC 编码族判断不等于所有 AAC profile 已验收，首个真实素材固定 AAC-LC。
- 首阶段排除 buffer.bounded、网络/HLS/RTMP、未知时长、iOS、DRM 以及其他输出格式；它们继续使用现有兼容播放。不得把“排除优化”表现为拒绝既有播放能力。
- 无公开开关、环境变量、逐缓冲计时器、零帧哨兵、插入静音或周期 reset；不接入此前失败的期限与分组方案。

## Review Focus

- 转换器已经持有 token：不能双重 reserve、提前释放仍被 PCM 持有的预算或覆盖旧代所有权（Task 3）。
- 首包 held、EOF/定时观察提交与暂停交错：以实际 PCM 提交锚定媒体时间，不能用后来压缩包的 PTS 或 rendered 资源计数伪造完成（Task 3/4）。
- stop/reset 同步触发回调、迟到回调与同线程重入：不能锁反转、死锁或扣减新代（Task 2/3/4）。
- 单尾部占满容量、后台无 display tick、rate/格式/路由改变：可测地回退或按既有错误链失败，不永久等待、不隐式恢复候选（Task 3/4）。
- 短节点实验通过但兼容回退恢复增长：长播、物理音画和最低系统证据分列，不能报告整体有界或默认准入（Task 5）。

## 接入决策与文件边界

生产源码根目录为 `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/`，下表的源码文件均相对此目录；测试与工具用仓库相对完整路径。

| 文件 | 责任 |
|---|---|
| 新建 `Audio/YlAudioCompletionPolicy.swift` | 纯准入判断、无敏感信息的拒绝原因、输出通知模式 |
| 修改 `Audio/YlAudioRenderer.swift` | 输出适配、已有 token 的资源所有权、提交时钟、最终排空 |
| 新建 `Audio/YlAudioTerminalState.swift` | 一块尾部、有限在途资源、单向回退和 generation 状态；不建立额外账本 |
| 修改 `Audio/YlAudioPipeline.swift` | 内部上下文注入、实际首次提交锚点、安装身份检查 |
| 修改 `Session/YlManagedPlaybackSession.swift` | 由真实 prepared/source/stream 数据构造上下文，内部默认关闭 |
| 修改 `packages/yl_player/example/macos/RunnerTests/YlMacosAudioTests.swift` | 策略、资源、时钟与控制定向回归；可复用同类内私有 PCM helper |
| 同步 `tool/consumer_fixtures/apple_flutter/RunnerTests-macos/YlMacosAudioTests.swift` | macOS 消费测试镜像 |
| 修改 shared `YlManagedFallbackCharacterizationTests.swift` | session EOF、seek、切轨和迟到锚点；三个路径见 Task 4 |
| 修改 `tool/consumer_fixtures/apple_flutter/main_example_tests.py` | 实际新增测试发现登记，不硬编码历史总数 |
| 新建 `tool/playback_benchmark/audio-integration-protocol.md` | 真实生产适配的测量协议；与工具模型证据分开 |

现有 `YlAudioRendererMaking.makeRenderer(bufferBudget: YlFallbackBufferBudget) -> YlAudioRenderer` 不改签名；在创建 renderer 后、configure 前注入上下文。默认输出协议桥接也维持既有 mock 行为。工具 `AudioTerminalBudgetPrototype` 保留作历史实验，生产代码不能依赖 tool 路径。

## 共同验证入口

所有新增 Swift 测试先只选目标方法，记录真实 RED 后实现；缺符号编译失败只证明接口未实现，还需在接口存在后观察行为断言失败。每项完成运行所在测试类；生产适配完成后才运行一次完整 macOS 套件。日志与 xcresult 用未使用过的 `/private/tmp/yl-audio-integration-*` 名称，不能覆盖失败证据。

```bash
python3 -B tool/run_with_display_awake.py xcodebuild test CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES -quiet -sdk macosx -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner -parallel-testing-enabled NO -derivedDataPath packages/yl_player/example/build/native-macos-tests -destination 'platform=macOS' -only-testing:RunnerTests/YlMacosAudioTests -resultBundlePath /private/tmp/yl-audio-integration-audio.xcresult
python3 -B tool/consumer_fixtures/apple_flutter/main_example_tests.py --current-only
```

第一条预期所选测试全部实际执行且零失败，第二条预期镜像/发现一致。定向时把 `-only-testing` 改为 `RunnerTests/YlMacosAudioTests/具体方法名`；session 用 `RunnerTests/YlManagedFallbackCharacterizationTests`；完整验收删除此参数。每次 commit 仅暂存该任务 Files 内实际改动及本计划/P08报告。

### Task 1：冻结可测试的候选准入策略

**Files:** 新建源码 `Audio/YlAudioCompletionPolicy.swift`；修改 macOS 音频测试、对应镜像与发现登记。

**Interfaces:** Consumes：`YlAudioCodec`、`YlApplePlatform`。Produces：以下内部值类型；数据缺失一律选择 legacy，不推测 URL 后缀。

```swift
struct YlAudioCompletionContext {
  let enabled: Bool
  let platform: YlApplePlatform
  let localFiniteSeekable: Bool
  let hasBoundedPlan: Bool
  let codec: YlAudioCodec
  let sampleRate: Double
  let channels: Int
  let rate: Float
}
enum YlAudioLegacyReason: Equatable {
  case disabled, platform, source, bounded, format, rate
}
enum YlAudioCompletionPolicy: Equatable {
  case legacy(YlAudioLegacyReason)
  case terminalCandidate
  static func select(_ context: YlAudioCompletionContext) -> Self
}
```

- [x] 写 `testTerminalPolicyRequiresExplicitEligibleContext`，至少固定下面的边界，不依赖真实设备声音：

```swift
let eligible = YlAudioCompletionContext(enabled: true, platform: .macos,
  localFiniteSeekable: true, hasBoundedPlan: false, codec: .aac,
  sampleRate: 48000, channels: 2, rate: 1)
XCTAssertEqual(YlAudioCompletionPolicy.select(eligible), .terminalCandidate)
let bounded = YlAudioCompletionContext(enabled: true, platform: .macos,
  localFiniteSeekable: true, hasBoundedPlan: true, codec: .aac,
  sampleRate: 48000, channels: 2, rate: 1)
XCTAssertEqual(YlAudioCompletionPolicy.select(bounded), .legacy(.bounded))
```

- [x] 增加单字段变化的 disabled/iOS/network/unknown duration/nonseekable、非 AAC、44.1kHz、6 声道、rate=2、NaN 回归；记录定向 RED。
- [x] 实现按 enabled→platform→source→bounded→format→rate 顺序的 guard，精确匹配已声明值；返回稳定枚举原因。来源布尔的真实构造由 Task 4 负责，不接触公开错误 API。
- [x] 运行定向测试与发现检查，预期每种排除均为具体 legacy 原因，符合条件才是 candidate。
- [x] 提交 `feat: define gated audio terminal eligibility`，更新本计划状态与报告；此时生产默认行为没有变化。

### Task 2：给输出驱动增加明确的通知选择

**Files:** 修改源码 `Audio/YlAudioCompletionPolicy.swift`、`Audio/YlAudioRenderer.swift`；修改 macOS 音频测试/镜像/发现登记。

**Interfaces:** Consumes：现有 `YlAudioOutputCallbacks`。Produces：

```swift
enum YlAudioOutputCompletionMode { case renderedResource, playedBack }
// 新增在 YlAudioOutputDriving，提供默认实现：
var supportsTerminalCompletion: Bool { get } // 默认 false，system output 为 true
func schedule(_ buffer: YlScheduledAudioBuffer,
              mode: YlAudioOutputCompletionMode,
              callbacks: YlAudioOutputCallbacks)
```

- [x] 写 `testDefaultOutputBridgeRemainsPlayedBack`：旧 TestAudioOutput 走新增入口仍只在原 completion 时触发资源与播放工作；不支持 candidate 的输出不得被准入。先运行 RED。
- [x] 实现默认方法转发到既有 `schedule(_:callbacks:)`。system output 用 `.dataRendered` 仅调用 `resourcesReleased`；`.dataPlayedBack` 调用 `playedBack`。复用现有一次性完成容器，禁止每缓冲新锁或 timer。

```swift
// 原生通知闭包只交付通知；不在 AVAudioEngine 线程同步等待 renderer operations。
switch mode {
case .renderedResource: callbacks.resourcesReleased()
case .playedBack: callbacks.playedBack()
}
```

- [x] 写 `testRenderedOutputNeverSendsPlayedBack`，分别显式交付资源/播放通知并断言工作计数；增加实际 engine 2 块 PCM 的 rendered/playedBack smoke，记录真实回调而非 sleep 后推定。
- [x] 用同步调用回调的 fake 和 reset 中调用旧回调的 fake 检查入口不会等待 renderer 锁；运行音频类及发现检查。此任务尚不改变 renderer 的默认调度模式。
- [x] 提交 `refactor: expose explicit audio output completion modes`。

### Task 3：renderer 接管已有预算并分开提交、资源与最终排空

**Files:** 新建源码 `Audio/YlAudioTerminalState.swift`；修改 `Audio/YlAudioRenderer.swift`；修改 macOS 音频测试/镜像/发现登记。

**Interfaces:** Consumes：Task 1/2、`YlScheduledAudioBuffer.reservation`、`YlManagedBufferLedger.Token.release()`。Produces：

```swift
// renderer：上下文必须在 configure 前设置；默认 nil 表示 legacy。
func setCompletionContext(_ context: YlAudioCompletionContext?)
var usesSubmissionAnchor: Bool { get }
var onFirstPCMSubmitted: ((UInt64, Int64) -> Void)? // generation, 实际 PCM ptsUs
func observeTailWait(playing: Bool, nowUs: UInt64)
func abandonTerminalCandidate() // 单向提交 held 尾部并切回 playedBack
```

`YlAudioTerminalState` 仅由 renderer 的 `operations` 串行操作。资源 owner 保存唯一可清空 PCM+token；ticket 含 completionGeneration 和 ordinal，资源集合仅包含尚未收到真实释放通知的项目；最多一块未提交尾部。外部回调捕获 owner/ticket，不额外复制带 PCM 的 buffer。renderer 原有 `hasPendingPlayback` 接口保留，但候选分支按 EOF/fence/剩余资源判定，不能继续从资源数量直接推导。

- [x] 用 `LifetimePCMConverter` 与支持明确模式的 fake 添加以下 RED：首块接纳返回 `.buffered`，输出空且 `renderedAudioTime == nil`；第二块接纳提交第一块；`finishInput()` 提交第二块作为 playedBack。记录提交 PTS，断言只有首个实际 PCM 触发一次锚点。

```swift
XCTAssertNil(renderer.renderedAudioTime) // 第一块仅 held 时
XCTAssertTrue(renderer.hasPendingPlayback)
renderer.finishInput()
// fake 交付普通 resourcesReleased 后，最终 playedBack 尚未到：
XCTAssertTrue(renderer.hasPendingPlayback)
// 交付最终通知和全部资源工作后，才允许：
XCTAssertFalse(renderer.hasPendingPlayback)
```

每段断言放在对应动作之后；测试不能直接修改 renderer 内部计数。补空输入、单 PCM、EOF 后入队拒绝、重复/乱序/错误类型通知及最后 legacy 块先完成后 EOF。
- [x] 补系统 converter 已持 token 与自定义 converter 由 renderer reserve 两条链的账本断言：单块 8192B，不是 16384B；尾部一直计费；真实释放后 PCM weak 引用为空且字节/时间只退还一次。保留 `carryTiming`/codec trim 形成的媒体范围，不能再次覆盖时间或 reserve。
- [x] 实现分离状态。资源预算恢复不推进位置；提交时更新已提交起止/节点锚点；位置依赖节点时间且上限为已提交 PCM 末尾，pause 时冻结，EOF 等 fence 时不能因资源为零返回空时钟。只保留有限资源与常量级时钟/最终 ticket 元数据，不保留所有已渲染历史。
- [x] 运行实际 PCM 格式检查：不是 48kHz、双声道、Float32 planar 或帧数不在 1…1024 时，先提交旧尾部、单向兼容后处理新 PCM；不丢新包、不重新解码。缺失/不合理 PTS 或时长同样兼容。容量不足且唯一资源是 held 尾部时先提交它走兼容，待真实通知后重试；绝不循环等待不可能到来的 rendered。
- [x] 回调通过每 renderer 一个串行交接队列异步进入 `operations`；读取状态沿用 state lock。output 调用期间不持 state lock，回调不在原生线程同步取 operations；停止前 fence 旧 generation，停止返回前不清除仍在输出使用的 owner。测试使用 expectation 确认异步交付完成，不用立即读值假定执行完毕。
- [x] 补暂停在途通知、node time 已越过末尾但 fence 未到、zero duration 兼容、同步重入、stop 迟到、reset 后旧通知、dispose 持有释放；音频类与镜像检查通过后提交 `feat: add gated audio terminal ownership state`。

### Task 4：接入首次提交锚点、观察定时器与控制生命周期

**Files:** 补充 `FFmpeg/YlDemuxPipeline.swift` 的只读实际随机访问能力转交；修改源码 `Audio/YlAudioRenderer.swift`、`Audio/YlAudioPipeline.swift`、`Session/YlManagedPlaybackSession.swift`；修改上述 macOS 音频测试及镜像；修改以下共享测试及发现登记：
- `packages/yl_player/example/macos/RunnerTests/YlManagedFallbackCharacterizationTests.swift`
- `packages/yl_player/example/ios/RunnerTests/YlManagedFallbackCharacterizationTests.swift`
- `tool/consumer_fixtures/apple_flutter/RunnerTests/YlManagedFallbackCharacterizationTests.swift`

**Interfaces:** Consumes：Task 3；`YlAudioTimeline.anchorAudio(ptsUs: Int64, sampleTime: Int64)`、既有 renderer factory。Produces：在 session initializer 末尾新增 `audioTerminalCandidateEnabled: Bool = false`；pipeline initializer 增加 `completionContext: YlAudioCompletionContext? = nil`，以 source 条件为基础在每次具体 stream/rate 配置时重建上下文。

- [x] 写 session 真实注入回归：默认不开、显式开本地有限候选、同素材加 bounded 仍旧模式、伪装本地后缀的 network recipe 仍旧模式。`localFiniteSeekable` 只可由 `.local` + `!prepared.policy.isLive` + `demux.isSeekable` + 正的实际 duration 共同成立；不可由 URL 判断。新 track/rebuild 不沿用旧格式结论。
- [x] 实现 pipeline `makeRenderer` 安装首次提交通知；在 main/session 所在执行上下文重新检查 renderer 身份及 audioGeneration 后才锚定。候选（包括同代回退）不走旧 enqueue 的压缩包锚点。legacy 保留原方法。

```swift
// 处理通过身份/代际检查的首个提交事件时：
// ptsUs 来自已 trim 的实际 PCM，不来自触发提交的下一个压缩包。
timeline?.anchorAudio(ptsUs: max(0, ptsUs), sampleTime: ptsUs)
```

不得在 renderer 的 state/operations 锁内同步取得 session lock；已 detach/seek 旧通知直接忽略。首块经 EOF 或 watchdog 提交也必须到达同一事件入口。添加首包 PTS 与第二包 PTS 不同、codec trim、迟到事件、视频在第一块 held 时不提前锚定的断言。
- [x] 每 renderer 最多一个 DispatchSourceTimer，目标 10ms，以 uptime 微秒调用 `observeTailWait`，独立于 display tick。只在有效候选播放时观察；暂停取消连续窗口，dispose/切回 legacy 取消 timer；闭包弱持 renderer。持续仅有尾部达到 100000µs 才回退；记录实际 gap，缺少 tick 不假报 100ms 硬实时保证。

```swift
// 在 fake 时钟/输出已建立“仅有尾部且 playing”的测试中：
renderer.observeTailWait(playing: true, nowUs: 0)
renderer.observeTailWait(playing: true, nowUs: 99_999)
// 输出仍未提交尾部。
renderer.observeTailWait(playing: true, nowUs: 100_000)
// 输出提交一次 playedBack 尾部；预算仍持有直到真实通知。
```

- [x] `setRate` 在改变原生 rate 前单向兼容；格式变化同 Task 3；graph/route 配置失效立即 fence 并沿现有失败/重建链处理，不能把已失效的图当仍可安全回退。不新增公开 route 错误码或静默吞错。seek/reset/切轨按停止后释放旧 owner、新代重新评估，普通 rendered 回调在兼容后仍按原类型处理。
- [x] 调整 silence/underrun：held 或 rendered 资源刚退还不等于音频空闲。等待尾部/fence 期间禁止静音补时；最终 playedBack 已确认且资源清空后可沿既有视频尾部逻辑补时。断供后的兼容路径须经过真实播放完成才恢复原有 gap 行为。保留 `buffer.bounded` 的原暂停判定。
- [x] 覆盖播放中暂停尾部、暂停期 EOF、恢复后窗口重置、无 display tick、切速后再回到 1 不重启候选、seek/切轨/graph 失效旧回调、视频长于音频、音频长于视频；用现有 session fixture 驱动完整 EOF completed，不能仅检查 renderer 的布尔。运行音频及 session 两类、镜像/发现检查后提交 `feat: integrate gated terminal audio clock and controls`。

### Task 5：真实生产路径验收与准入报告

**Files:** 新建 `tool/playback_benchmark/audio-integration-protocol.md`；修改 macOS 音频/session 测试及镜像/发现登记；更新 `docs/superpowers/reports/2026-09-26-remaining-08-performance-release.md`、本计划和总览。新建 `tool/playback_benchmark/macos-audio-integration-observations.json` 存源码身份、协议、原始结果与失败；不得覆盖历史工具实验。

**Interfaces:** Consumes：Task 4 的内部显式注入、现有原生 XCTest runner、`main_example_tests.py` 实际发现检查。Produces：报告明确列出 `adapterImplemented`、`defaultEnabled=false`、`productionAdmission=false`、`downstreamBoundProven`（只由独立证据决定）；局部通过不能修改默认值。

- [x] 在真实运行之前冻结素材哈希、源码/编译身份、系统设备/路由、电源/热状态、同条件 legacy/candidate 对照、计划数量与失败保留规则。最小集：0/1/3/2000 PCM、300ms 断供、在途 pause/EOF、seek/切轨/rate/graph invalidation；真实 converter 与 session 必须各有记录，不能只运行工具模型。
- [x] 新增实际 adapter 的节点 tap 回归，检查所有输入帧只交付一次且顺序正确；沿用工具的有限短序列 Float32 marker，第一声道 tap 与最终 mixer 静音必须标明。正常 2000 块零内部零帧；断供组完整保留 gap 并验证单向回退，不称连续无间断。记录提交/回调 mode、generation、时钟锚点及 ledger 峰值；EOF 只在最终通知/资源清空后出现。
- [x] 用 fake callback 丢失及旧 generation 通知确认不会伪造 completed；用真实故障记录现有安全错误字段，不记录 URL/headers/原生异常原文到公开诊断。
- [x] 运行一次完整 macOS 原生套件与实际发现检查，保留 xcresult 身份、失败与跳过；共享代码需要 iOS 编译检查，未运行的 iOS/最低系统/Intel 行明确未验收。只有工具校验器改动时才运行对应 Python 回归，不因文档变更重跑全套。
- [x] 独立冻结并执行同会话至少 1200s 的无 MSL、播放中无 heap 连续性观察；另开资源取证运行，不能把 heap 干扰组算作连续性通过。复用 P08 已冻结进度/失败规则，记录 RSS/footprint/owned PCM/回调外壳与 timer 的前中后变化和释放后值；协议在执行前写清新增指标的阈值依据，不能事后以观测最大值定合格线。若下游总体边界证据仍不足，保留 `downstreamBoundProven=false`，输出资源变化原值。
- [x] 分开汇总：定向行为、真实节点、长播连续性、独立资源、物理音画、设备/最低 OS。兼容回退恢复逐缓冲对象保留是已知限制，不能从稳态组外推所有来源。缺设备或物理证据记录具体缺口，继续能完成的范围。
- [x] 提交 `test: validate gated audio terminal integration`。这五项完成只代表测试适配与证据完成；默认启用需另一个有明确支持矩阵与资源/音画结论的发布切片。完整 P08 Task 1/2 不随本子计划自动勾选。

## 自审与交付边界

2026-10-08 文档自审：准入与 bounded 排除→Task 1/4；通知来源→Task 2；既有 token/所有权与输出排空→Task 3；时钟/控制/定时器→Task 4；独立长播及未准入状态→Task 5。新接口均由前序任务定义，默认 factory 签名保持不变；测试路径按仓库实际镜像核查。历史 §4/7 的否决不被新计划改写。

规划提交 `184531f` 只包含文档。后续 Task 1–5 已完成下述接口、验证执行与证据分类；沿用用户已授权的本会话实现与本地提交，不推送远端。

### 2026-10-08 Task 1 执行记录

新增内部纯选择器与稳定排除原因；四项回归覆盖显式开关、平台/来源/bounded、非 AAC、采样率/声道、倍速及非有限数值、多条件排除优先级。先缺接口编译失败，再以恒定 legacy(disabled) 骨架观察四项行为失败（原32项通过）；最终音频36/36、夹具4/4通过，发现清单iOS669/macOS608核对。

来源资格在当前接口是单一布尔值，本项只验证 false 被排除；network/未知时长/不可seek 的实际事实构造在 Task 4 验证，不将重复同一 false 输入写成三个集成通过。实际 PCM 帧数/布局与输出支持仍在 Task 3/4。未连接 renderer 或新增公开配置，不改变生产调度，也不报告内存改善；完整原生/iOS/物理设备与长播未在本项执行。原始结果和源码身份见[证据](../../../tool/playback_benchmark/macos-audio-policy-observations.json)。

### 2026-10-08 Task 2 执行记录

新增明确模式和输出能力标志，旧驱动默认 false 并转交既有 callbacks 入口；system 新入口分别采用 dataRendered/resource-only 与 dataPlayedBack/playback 通知。拒绝未配置、已dispose或非PCM输入时，新入口只退还资源，不能假报已播放；旧入口保持兼容。回调直接在系统线程交付，串行交接由 Task 3 调用者实现，不新增锁或 timer。

缺接口编译RED后，兼容桥接骨架39通过/2失败；真实native失败详情确认 rendered 误触发 inverted playedBack expectation，拒绝输入也误发播放通知。实现后音频41/41、夹具4/4通过，镜像发现669/613核对。新增五项覆盖旧接口延迟/重复回调、真实双PCM模式、三种拒绝状态×两模式、同步重入、renderer reset内旧回调。真实native为静音48kHz双声道、每块1024帧、4秒有界观察；不验证物理音画或资源增长。

[完整证据](../../../tool/playback_benchmark/macos-audio-output-modes-observations.json)保留初始编译、行为失败、最终结果与源码。既有renderer类主体逐字节未改，生产调用尚未选择新模式；能力标志不等于候选准入，Task 3必须检查输出能力并实现所有权/最终排空。未运行完整macOS/iOS/最低系统或长播；下一项 Task 3。

### 2026-10-08 Task 3 执行记录

完成内部显式启用的 renderer 状态接入：一块真实 held PCM、最多24个在途所有者、既有字节/时长上限、按资源通知归还上游预算、独立末尾播放通知。每代 ticket 包含 epoch/ordinal；回调仅将标量投递到每renderer一条惰性串行队列，在 operations 下核验代际/类型并一次性退还。旧输出停止返回后才清空旧PCM，迟到通知不能影响新代。默认上下文nil，session未注入；没有公开开关或观察timer。

转换器协议补充 `reservesOutputBuffers`（默认false、system为true），接管转换器已有token而非重复reserve；自定义不自行预留者仍在转换前保守计费。真实benchmark_sdr.mkv的AAC转换器输出和自定义已预留路径均确认一块8192B音频预算。真实转换测试用可控输出，不能据此称真实终端输出或全session验证。已持有的mediaEpoch/timing不重新覆盖；实际bounded plan或scope timeline均不允许候选。

首块held不锚定或计作已提交，实际提交才发一次generation/PTS事件；时钟受已提交末尾限制，rendered不推进位置，暂停冻结，EOF必须等末尾通知及所有资源。格式/帧数/PTS异常先单向兼容，保持原PCM；预准入容量不足且只有held尾部时先提交它，等待真实回调再试。转换完成后才发现估计不足则沿现有policy.unsupported失败链，不把已消耗输入当可安全重试；自持预算转换器内部发生容量错误也保留原错误。100ms观察接口只由显式调用驱动，自动定时观察仍属Task4。

新增15项回归，缺接口失败后核心行为实际RED；首轮50/50通过后，复核的held/underrun、真实bounded scope、调度重入reset三项分别实际RED→GREEN。最终音频56/56、夹具4/4通过，镜像发现669/628一致；源码与全部结果见[证据](../../../tool/playback_benchmark/macos-audio-terminal-owner-observations.json)。未运行全macOS/iOS、长播或物理音画；旧兼容路径的系统对象保留限制仍在。下一项Task4负责session来源事实、首次提交锚点接收、定时器、路由及完整控制交接。


### 2026-10-08 Task 4 执行记录

内部 session 新增默认 false 的候选开关，pipeline 接收来源上下文，并按每次实际 stream/desiredRate 配置。来源准入使用 recipe、非直播策略、seekability 与实际正时长；重建额外读取重新打开输入的随机访问能力与时长，network/live reconnect 明确排除。本项没有新增公开配置，也未启用默认业务路径。

首块真正提交后，pipeline 在 main/session 锁下复核 renderer 身份与 audioGeneration，再以 trim 后 PCM 的 PTS 锚定一次；同代兼容回退继续使用该入口。每 renderer 一条串行队列、最多一个 10ms 目标观察 timer，以 uptime 微秒检测连续 100000µs 的仅尾部等待；暂停取消窗口，EOF/兼容/reset/dispose 取消观察，弱引用不延长 renderer 生命周期。本次无 display tick 回归的最大观察 gap 为10826µs（10.826ms），仅为该次观测，不将目标间隔写成硬实时承诺。

AVAudioEngine 配置失效通知按 epoch 异步 fence、停止输出后退还 owner，沿既有 render.audio_engine_failed 链报告，不向失效图提交暂存尾部；失效后的 play 明确抛出同一安全错误。所有输出钩子均在 state lock 外调用。此次没有新增 route 公开错误码。

新增4项音频与7项共享 session 回归：timer 缺失、失效后静默 play、清理钩子占用 state lock 三个边界均保留实际 RED→GREEN；最终两类113/113通过（音频60、session53；0失败/0跳过），夹具4/4、发现iOS676/macOS639核对。真实 demux 的 opus_switch 素材经受控 PCM/video 截止点覆盖音频/视频分别先结束，完整 session 到达 completed；该组不是物理音画或真实解码连续性验收。来源默认/本地/bounded/network、trim 锚点、EOF/watchdog、同 owner 旧代、实际 seek/切轨与图失效链均有回归。

[证据](../../../tool/playback_benchmark/macos-audio-terminal-integration-controls-observations.json)保留运行日志、结果/方法身份、观察附件、最终源码及素材哈希；中间源码未逐版归档。既有编译/链接/QoS警告保留，未运行完整macOS、iOS、最低系统/Intel或长播。下一项 Task5 负责真实节点集成、完整套件、独立长播/资源采证和全计划复审；defaultEnabled/productionAdmission/downstreamBoundProven 仍为 false，完整P08开放。


### 2026-10-08 Task 5 执行记录

完成真实renderer/system节点短序列矩阵、实际converter/session控制与EOF、安全失败及回调丢失检查。资源采样发现既有释放后clock读取原生崩溃，新增独立回归实际RED1/1→GREEN1/1并最小guard修复。复审前完整macOS644/644、实际发现核对通过，iOS arm64模拟器编译通过；未运行iOS/最低OS/Intel设备验收。

无heap独立长播241采样/1200.317s通过：57840640帧，顺序错误和内部零帧0，56484rendered+1playedBack提交/回调一致，ledger峰值196608B，释放与2秒后0。独立paired资源组四阶段均采齐，但两组在播放中heap之后均出现tap帧丢失/顺序断言失败，退出65原样保留，不放宽断言、不算连续性通过。该项勾选表示实现、执行与准入报告完成，绝不表示所有实验通过。

完整数据、失败归因边界及协议偏差见[P08报告](../reports/2026-09-26-remaining-08-performance-release.md)和[证据](../../../tool/playback_benchmark/macos-audio-integration-observations.json)。adapterImplemented=true，defaultEnabled/productionAdmission/downstreamBoundProven=false；物理音画、真实路由切换、其他设备/最低系统及整体资源上界待后续发布切片，完整P08保持开放。


全子计划fresh复审覆盖184531f..421103c，1个Important/P2、无Critical/Minor：同步调度重入pause可能按旧状态重启。新增回归实际RED1/1，再于startOutput前复核当前playbackRequested/disposed/generation；最终完整macOS645/645、0失败/0跳过，实际发现、iOS arm64编译和夹具4/4均通过。未再派发复审。长播与heap保留421103c的测量身份，未对复审修复后二进制重新执行；最终发布前仍需复测，不能借用旧测量身份。所有执行决策、代价与未判断项见P08报告，默认及正式准入保持关闭。


### 后续验证：修复后版本身份复测（2026-10-08）

沿用P08已有长期观察要求，补齐cf094a7的明确测量缺口；[冻结协议](../../../tool/playback_benchmark/audio-final-revalidation-protocol.md)在运行前保存。不修改生产或测试代码，不重复已验证且身份一致的645/645套件和iOS编译。

- [x] 核对当前源码/二进制/素材与最终完整套件、脚本与已归档版本一致，冻结输入与计划三次独立运行。
- [x] 对修复后版本独立执行>=1200s无heap长播，按原阈值校验，保留原始结果。
- [x] 顺序执行legacy/candidate四阶段heap资源取证；帧断言失败仍记失败，不放宽门槛。
- [x] 归档新的版本身份与完整证据，更新报告/总览并本地提交；物理设备/整体有界/正式准入仍开放。

执行结果：cf094a7独立长播1/1及冻结校验通过（241采样/1200.300s/57840640帧，顺序错误与内部零帧0）；ledger峰值196608B、释放后0。资源两组frame/order均失败，legacy中段heap8秒超时，只有7/8有效heap快照；所有失败与缺失保留，勾选表示计划测量已执行并报告，不表示资源验收通过。源码/二进制/素材与645/645既有套件身份完全一致，本项无实现改动。详见P08报告及独立复测证据；正式准入仍关闭。

### 后续验证：自然 EOF 后资源取证（2026-10-09）

- [x] 验证暂停后采样假设；无heap帧序回归失败，保存失败/源码并移除该模式。
- [x] 增加播放中不取heap的自然EOF资源模式，RED→GREEN及音频类66/66、夹具4/4通过。
- [x] 冻结协议/身份，顺序执行legacy/candidate各1000/2000块四组，保存全部结果。
- [x] 独立复审采集器；修复部分表格误收，9/9 Python通过，离线严格核对12份原始heap。
- [x] 归档原始证据、更新报告/总览；不修改生产或开放准入。

四组帧序完整、顺序错误/内部零帧均0，12/12heap均在8秒内完成；排空后legacy完成回调对象随长度为1000/2000，candidate未单独识别。此次仅闭合排空后采证方法，未闭合旧live-heap干扰/超时、物理音画或整体资源有界。最终完整性校验是采后Python修复，原始四组采集身份保留；不重复原生或长播。下一项真实解码有限长片的无heap连续播放/时钟观察，详见[P08报告](../reports/2026-09-26-remaining-08-performance-release.md)及[证据](../../../tool/playback_benchmark/macos-audio-postdrain-resources-observations.json)。

### 后续验证：真实解码短程门禁与长程阻塞（2026-10-09）

- [x] 冻结真实AVC/AAC素材及内部时钟/视频选择观测范围，新增短程与条件长程入口。
- [x] 执行30秒短程；保留v1采集失败和观测修正后的独立诊断失败。
- [x] 修复复审3项Important与2项Minor，音频67/67、Python8/8、夹具4/4通过。
- [x] 实测确认首PCM负PTS−21000µs触发兼容回退；归档源码、二进制、素材、原始数据和报告。
- [ ] 候选真实解码短程通过：当前实际全部playedBack，rendered0。
- [ ] 1200秒真实解码候选长程：被短程门禁阻塞，未运行。

下一项处理AAC负起始PTS/编码预滚，维持裁剪/首段连续性/时钟正确性后重新短程验收，再启动长程。当前生产无修改，准入仍关闭。详见[报告](../reports/2026-09-26-remaining-08-performance-release.md)与[证据](../../../tool/playback_benchmark/macos-decoded-continuity-observations.json)。

### 后续修复：限定 AAC 初始预滚（2026-10-09）

- [x] 按采样帧裁剪一次初始负前缀，保留后续样本与原分配预算；未改变默认路径。
- [x] 四项内容/预算/锚点/兼容回归RED→GREEN，复审重复裁剪问题RED→GREEN并验证reset。
- [x] 最终macOS651/651、iOS arm64编译、Python8/8、夹具4/4及发现678/652核对。
- [x] 同版本真实解码短程30.027s通过，无兼容回退。
- [x] 执行1201.131s长程并归档失败：241点、无音频回退，1次视频drop。
- [ ] 真实解码候选长程零丢帧验收：仍未通过，下一项细分drop路径及调度原因。

窗口860.818–865.827s中drop从0增至1，原生与严格校验均失败。没有重试覆盖或放宽阈值；资源释放后ledger0不代表整体资源有界或完整文件EOF通过。详见[报告](../reports/2026-09-26-remaining-08-performance-release.md)和[证据](../../../tool/playback_benchmark/macos-aac-preroll-observations.json)。正式准入继续关闭。

### 后续定位：视频丢帧分类与调度窗口（2026-10-09）

- [x] 默认关闭、最多16事件的标量诊断，原子记录总量/六类原因/等待生产者数；不修改调度行为。
- [x] 原生RED3失败/1通过→最终macOS655/655；iOS arm64编译、Python10/10、夹具4/4；复审竞态及错误记录校验均已修正。
- [x] 同版本30.025s短程通过；播放drop0，释放阶段单独记录1次容量等待超时。
- [x] 执行一次目标1200s长程并归档实际870.888s失败前缀：10次enqueueTimeout、媒体/音频时钟停滞，随后render.audio_engine_failed。
- [x] 音频停滞归因：进程级日志证实上轮为默认输出路由切换及引擎配置失效；分支证据补强已完成，详见后续记录。实际恢复能力另行验收。
- [ ] 最终长程验收与候选准入：仍未通过，本次未达到1200s；不得推断上轮单次drop原因相同。

详细证据与限制见[报告](../reports/2026-09-26-remaining-08-performance-release.md)及[归档](../../../tool/playback_benchmark/macos-video-drop-diagnostics-observations.json)。生产准入和默认启用保持关闭。

### 后续归因：音频路由变化与安全分支记录（2026-10-09）

- [x] 恢复上轮进程43219的限定窗口系统日志，确认默认输出设备变化、IO传输中断、引擎配置变化停机与通知；归档12条脱敏记录及原日志指纹。
- [x] 验收探针增加32条有界事件、安全错误详情、原生节点时钟及engineRunning；启动同步失败保存前缀再抛出。
- [x] 真实通知/原生启动失败回归RED2→GREEN2；复审启动前缀RED1及倒序原因负例修正；最终macOS656/656、Python13/13、夹具4/4、发现678/657核对。
- [x] 冻结版本30.025s短程通过，播放drop0、两次启动成功、无配置失效/启动失败；释放事件分开保留。
- [x] 补齐音频输出配置失效/启动失败的明确用户提示与重新加载指引，保持错误码、安全边界和失效旧图停止策略；见下方验证记录。
- [ ] 带路由事件记录的1200s长程与实际恢复验收：尚未完成，本轮未重复长程；历史失败不改写，候选准入继续关闭。

本次没有生产行为修改或实际设备切换；更多细节见[报告](../reports/2026-09-26-remaining-08-performance-release.md)和[证据](../../../tool/playback_benchmark/macos-audio-failure-cause-observations.json)。

### 后续提示：音频输出失败与显式重新加载（2026-10-09）

- [x] Swift/Dart公开边界均为既有`render.audio_engine_failed`提供固定音频设备检查与重新加载提示；不使用原生message/diagnostic推断设备切换原因，retryable仍为false。
- [x] 接入文档说明由用户显式调用`player.load`重建并使用新session；失败旧图不能反复play，不承诺自动保留位置/轨道。
- [x] 原生发布边界RED1→GREEN；最终定向9/9（含配置通知/启动失败及停止后禁止重播）、Dart Apple112/112、平台接口123/123、夹具4/4、发现678/657；iOS arm64编译通过，未运行iOS测试。
- [x] 显式Load重建后的受控恢复验收：真实解码/音频输出、新session、旧图隔离及失败Load安全传播两场景通过，详见后续记录。实际设备切换恢复仍未证明。
- [x] 带音频配置事件记录的1200s长程：本轮1201.179s/241点通过，播放drop0；历史失败保留，实际设备切换恢复仍单独验收。

本项只改变固定公开提示并完善接入指引，不改变输出生命周期或启用候选。本轮不重复完整macOS套件及短/长程播放；历史长程失败和正式准入关闭保持不变。

### 后续恢复：显式 Host Load 重建输出（2026-10-09）

- [x] 内部audioRendererFactory与默认false的候选开关贯通Host→Coordinator→Fallback→Session，不修改公开协议或默认行为。
- [x] 两项真实AVC/AAC解码/AVAudioEngine定向测试通过：配置失效后显式Load恢复；候选原生输出启动失败使首次重载被拒，随后显式重载恢复。
- [x] 新session/输出及首帧、节点时钟、媒体位置推进均检查；旧session命令拒绝、旧图无新提交、迟到失败回调不污染新会话；最终所有输出停止且账本0。
- [x] 最终macOS完整原生658/658、0失败/0跳过；发现iOS678/macOS659及运行清单核对、夹具4/4；iOS arm64编译exit0（未运行iOS测试）。

作用域为向自有engine发布配置通知及使候选原生output在play前失效，不变更系统音频设备。短程物理音画、真实设备切换、长程零丢帧与整体有界均不能由本项推导。详见[协议](../../../tool/playback_benchmark/audio-reload-recovery-protocol.md)、[证据](../../../tool/playback_benchmark/macos-audio-reload-recovery-observations.json)和[报告](../reports/2026-09-26-remaining-08-performance-release.md)。

### 后续长程：携带音频配置事件的连续性验收（2026-10-09）

- [x] 现有采集器13/13回归；同版本30.028s短程门禁通过，源码/二进制/素材/协议身份冻结且与长程一致。
- [x] 正式长程1201.179s、241采样、28915个调度视频帧；播放drop0、orderErrors0，无候选回退或音频配置失效/启动失败，XCTest与严格采集器均通过。
- [x] 音频时钟累计偏差+1.555069s（原门限±5s）、最大选帧滞后23125µs（原门限100000µs）；未调整判定标准。
- [x] 释放阶段单独记录1次enqueueTimeout约251.045ms；立即及2秒后均ledger0、pendingfalse、nativePlayingfalse。该计数不混入活动播放。
- [x] 短/长程原始JSONL、结果包导出、音频/drop事件、源码/二进制/素材指纹已归档。无生产改动，无完整原生/iOS重复执行声明。
- [x] 真实解码自然EOF与尾部排空验收：后续79/79回归通过，最终playedBack/资源释放与公开completed时序已验证；长程主动停止证据仍不冒充EOF。

本次配置失效通知为0，证明本次记录中未发生该事件，不能据此宣称真实设备切换恢复已通过。物理音画、实际设备切换、最低系统/Intel/iOS运行及整体资源上界仍开放，defaultEnabled/productionAdmission/downstreamBoundProven均为false。历史单drop与路由失效失败原档保持不变。见[报告](../reports/2026-09-26-remaining-08-performance-release.md)与[证据](../../../tool/playback_benchmark/macos-route-monitored-long-observations.json)。

### 后续 EOF：真实解码尾部完成与暂停边界（2026-10-09）

- [x] 使用已有4.021s AVC/AAC、48kHz双声道本地文件，真实Host Load/解码/原生音频输出，正常到达EOF后才关闭。
- [x] 两项定向验收初次通过：自然转交原生尾回调；持有真实playedBack回调，暂停后转交，排空仍保持paused，resume后才发布completed。
- [x] 完成时检查普通rendered资源回调齐全、恰好一次尾部playedBack、原生→转交→公开完成时序及音频bytes0/pendingfalse。
- [x] 复审补齐迟到回调断言：重复转交后检查renderer/host状态；close后比对全部公开事件计数，镜像同步。
- [x] 最终音频类及三项受控EOF回归79/79、0失败/0跳过；夹具4/4、发现iOS678/macOS661核对；43份带hash原始证据归档。
- [x] 真实解码路径的独立资源对照取证：两独立进程、6份有效heap；详见后续记录，保持播放连续性与资源测量互不替代。

本轮只修改测试/证据工具，生产默认关闭策略不变。不重跑iOS或20分钟长程，已有结果保持原版本身份。真实设备切换、物理音画、平台矩阵及整体资源上界继续开放。详见[协议](../../../tool/playback_benchmark/decoded-natural-eof-protocol.md)、[证据](../../../tool/playback_benchmark/macos-decoded-natural-eof-observations.json)和[报告](../reports/2026-09-26-remaining-08-performance-release.md)。


### 后续资源：真实解码自然 EOF 后独立对照（2026-10-09）

- [x] 默认/候选各独立进程，冻结同一源码、二进制和4.021s AVC/AAC素材；configured/drained/disposed各采heap，completed仅观察，播放期间不采堆。
- [x] 自然完成后先确认原生回调与音频排空，再pause原生节点保留graph；明确区分固定arm与dispose后清除的实际submissionAnchor。
- [x] 复审发现ACK超时仍可继续播放，改为30s超时抛错并关闭Host；回归覆盖缺ACK中止和已有ACK继续，复核关闭。
- [x] 两组6/6 heap均在原8s期限内取得完整表格、ownedPID及一致汇总；正式XCTest各1/1、最终定向4/4、资源工具25/25、夹具4/4，发现iOS678/macOS663。
- [x] 两组完成时audioOwned0/pendingfalse，总ledger92944；close后立即及>=2s均ledger0、原生输出停止。默认189 playedBack，候选188 rendered+1 playedBack，全部回调到达。
- [x] 119份原始数据/hash归档。进程堆close后仍可能增长，保留原始RSS/footprint与heap结果，不将受管资源释放等同全进程回收。
- [x] 真实解码自然EOF资源对照的播放长度矩阵：4/30/60s两路径共6组已完成，保留趋势见后续记录；不以EOF快照代替活动播放上界证明。

本次仅测试/采集工具/文档，无生产修改；未重跑完整原生套件、iOS或1200s长程。defaultEnabled/productionAdmission/downstreamBoundProven继续false。单对照不支持统计性优化结论；实际设备切换、物理音画、平台矩阵及整体资源上界仍开放。见[协议](../../../tool/playback_benchmark/decoded-eof-resources-protocol.md)、[证据](../../../tool/playback_benchmark/macos-decoded-eof-resource-observations.json)及[报告](../reports/2026-09-26-remaining-08-performance-release.md)。


长度矩阵执行裁定（2026-10-09）：采用同一现有1260s素材的4/30/60s前缀、两路径各独立进程共6组；清除测试进度事件历史以避免随时间人为增长。原8s heap/30s ACK/180s native/240s parent不变；自然完成等待按素材长度+10s。报告探索性趋势，不设事后内存阈值或据此开启准入。


### 后续长度矩阵：4/30/60s独立资源对照（2026-10-09）

- [x] 同一自有长素材stream-copy三个前缀，实际容器时长4.229/30.229/60.229s；素材、probe、命令与hash归档。
- [x] 清空高频progress事件历史，只保留计数；定向4/4、资源工具27/27、矩阵工具3/3、夹具4/4、发现678/663通过。
- [x] 初次配置快照观察到1条待确认order事件，三组中两组collector失败（native及9份heap均通过）；暂停调度器并在当前组结束后终止，保留全部记录。
- [x] 每个快照前最多等待5s让在途ACK清空，超时throw清理；不放宽数组为空、8s heap、30s collector ACK、180s native或240s parent条件。复核通过，以新身份重新执行全部六组。
- [x] 正式6/6组通过、18/18完整heap有效（2.201–5.615s），所有源码/二进制身份相同；实际播放约4.35/30.31/60.27s，提交188/1407/2813，各长度两路径一致。
- [x] 自然完成时音频owned0/pendingfalse，总ledger92944；close后立即及>=2s均ledger0/输出停止，保留public事件10、progress/order数组0。
- [x] 默认drained−configured随长度为96,832/1,089,408/1,728,496字节；候选24,400/207,648/193,616字节。保存全部原始量，不能把单次较小增量升级为整体有界或统计性改善。
- [x] 372份原始文件归档，初次失败与最终通过均保留；只改测试/工具/文档，无生产修改，不重跑完整套件、iOS或1200s长程。
- [x] 完成EOF后增长的类型级归因与冻结源码核对；已定位可识别容器和通用分配类别，精确持有链与测试包装贡献尚待后续对照，不据此确定生产修复。

详见[矩阵协议](../../../tool/playback_benchmark/decoded-resource-length-protocol.md)、[证据](../../../tool/playback_benchmark/macos-decoded-resource-length-observations.json)及[报告](../reports/2026-09-26-remaining-08-performance-release.md)。defaultEnabled/productionAdmission/downstreamBoundProven均false。


### 后续归因：离线堆类型核算与源码边界（2026-10-09）

本轮先复用既有18份最终heap完成类型级归因；未取得新的对象地址、分配栈或retainer graph，因此不把这一子步骤写成精确所有者/完整因果归因已完成。

- [x] 离线分析直接读取已提交长度矩阵archive，核对六组身份、18份gzip长度/hash/PID/完整表与汇总；不依赖临时进程或重新播放。
- [x] 保留CLASS_NAME/TYPE/BINARY联合标签及重复行，正确处理named malloc空TYPE；未单独识别保持null，不填0；全表及阶段差额数量/字节守恒。
- [x] 默认EOF后LifecycleCompletion为188/1407/2778（12032/90048/177792B）；候选及全部disposed快照未单独识别此类型。默认dispatch/Block/Closure类别随长度增加，候选无相同趋势。
- [x] 60s相对4s且扣除各自configured基线：默认净增1,631,664B，其中四类记录1,032,096B、non-object647,648B、其他−48,080B；候选169,216B=192+260,688−91,664B，保留负贡献。
- [x] 冻结源码核对：默认逐提交创建完成容器，回调清空资源/播放闭包；候选使用不同提交路径；测试IntegrationOutput额外包裹回调。因此容器计数不等同PCM存活量，通用闭包不能全部算作生产成本。
- [x] 复审修复重复/冲突Process头、顶层与cell身份不符、probe字节长度不符三个校验缺口，均有RED→GREEN负例；离线归因10/10、既有资源27/27、矩阵3/3通过。
- [x] 测试适配器透明转交对照完成：四组同版本独立进程，观察包装相关差异与仍存在的容器保留；单次结果不认定精确包装成本，见后续记录。

本轮无生产/原生测试代码修改，没有新native/iOS/长程或heap/MSL运行。defaultEnabled/productionAdmission/downstreamBoundProven继续false。见[协议](../../../tool/playback_benchmark/decoded-heap-attribution-protocol.md)、[派生证据](../../../tool/playback_benchmark/macos-decoded-heap-attribution-observations.json)和[报告](../reports/2026-09-26-remaining-08-performance-release.md)。


### 后续干预：测试回调透明转交对照（2026-10-09）

- [x] 仅测试适配器新增透明转交，保留提交/状态/资源检查；原生callback次数标记unobserved/null，不伪造为0或提交次数。
- [x] 默认/候选×包装/透明四组同源码/二进制、四独立进程串行；60s素材每组2813提交、自然EOF及关闭后两点释放通过，12/12 heap在8s内有效。
- [x] 默认透明仍识别2813个LifecycleCompletion和3108个dispatch source，Closure context相对包装减少5624；不能把测试包装当作全部保留的原因。
- [x] 分别扣基线后的包装减透明总堆差默认+673,568B、候选+10,432B；仅单次观察，不证明精确成本、统计改善、原生持有链或整体有界。
- [x] 复审两个P2校验修复并实际RED→GREEN；原生4/4、Python45/45、夹具4/4、发现678/663，194份原始文件归档。无生产改动，不重跑完整native/iOS/长程。
- [x] 默认透明路径hold/stop独立对照完成：stop之后、图拆除之前观察到容器条目消失；没有精确原生持有链结论，见后续记录。

见[协议](../../../tool/playback_benchmark/decoded-callback-wrapper-protocol.md)、[证据](../../../tool/playback_benchmark/macos-callback-wrapper-observations.json)和[报告](../reports/2026-09-26-remaining-08-performance-release.md)。候选默认/正式准入/整体有界三项仍false。

本项执行裁定（2026-10-09）：复用当前codex/fel-integration工作目录与原生消费工程。采用默认透明回调hold/stop两独立进程；两者drained ACK后等时等待2s，仅stop组直接调用唯一原生player.stop，保持engine及附着节点集不变，随后采intervened heap再关闭。加入等时hold控制采样等待影响。维持原超时/释放门限；无生产代码修改。先校验负例与定向回归，再冻结正式两组、复审/归档/本地提交。


### 后续边界：自然EOF后保持暂停与仅stop对照（2026-10-09）

- [x] 仅测试直接操作唯一原生player，hold/stop均drained ACK后等待>=2s；intervened保持原四节点集合与engine运行，之后才完整close。
- [x] 同源码/二进制/60s素材两独立串行进程2/2通过，各2813提交；8/8 heap在原8s内有效，透明callback继续null，EOF及关闭后两点资源/事件检查通过。
- [x] hold中2813完成容器保持列出，stop后不再单独识别；dispatch3110→221，closure3358→389。支持本次变化发生在图拆除前的stop边界，不声明零存活或精确retainer。
- [x] 负例RED→GREEN；定向原生4/4、工具50/50、夹具4/4、发现678/663，独立复审无P1/P2，140份文件归档。无生产修改，无完整native/iOS/长程重跑。
- [x] 最终复审披露hold/stop观察间隔4.998/18.620s（显式sleep均约2s）；额外延迟来源未分段测量，未完成时间效应与stop因果贡献分离。
- [x] 分段计时与预设30s更长纯等待对照完成；三种实际窗口覆盖通过，本轮同步stop耗时已直接记录，见后续记录。

见[协议](../../../tool/playback_benchmark/decoded-stop-boundary-protocol.md)、[证据](../../../tool/playback_benchmark/macos-stop-boundary-observations.json)与[报告](../reports/2026-09-26-remaining-08-performance-release.md)。候选默认、正式准入及整体有界仍false。

分段计时执行裁定（2026-10-09）：延续2f9b63f证据，不将残余延迟归为stop。正式同版本默认透明两进程先hold30s、后stop等待2s；记录ACK/等待/同步动作/断言/探针/记录清空/内存读取/行捕获的单调时刻。按实际行间隔、ACK后间隔和heap-start间隔核对hold覆盖，未覆盖明确false。原超时与EOF/图/账本门限不变，短程原生保留2s等待，生产未改。


### 后续时间对照：分段计时与30s纯等待（2026-10-09）

- [x] 测试记录ACK/睡眠/同步动作/断言/探针/记录清空/内存读取/行生成；单调、有限、不可后改，总和守恒，透明callback仍null。
- [x] 首次hold原生通过但2份heap超时、stop未启动，失败保留；同身份/原门限仅一次完整复测。
- [x] 复测默认透明hold30s/stop2s，两独立同版本进程2/2、8/8heap；实际行/ACK后/heap开始三种窗口均由hold覆盖，未以预设sleep替代覆盖证据。
- [x] 本轮同步stop测得12.145656s，不能反推旧轮耗时或推广为上界；MainActor同步调用成本阻止直接生产接入。
- [x] 定向原生4/4、工具53/53、夹具4/4、发现678/663、199份证据归档，无生产修改、无完整原生/iOS/长程重跑。
- [x] 默认/候选同步stop同版本独立对照完成，实际模式与计时均验证；不直接在生产主线程增加自动stop，见后续记录。

详见[协议](../../../tool/playback_benchmark/decoded-stop-timing-protocol.md)、[证据](../../../tool/playback_benchmark/macos-stop-timing-observations.json)及[报告](../reports/2026-09-26-remaining-08-performance-release.md)。候选默认与准入仍关闭，整体有界未证明。

停止路径对照裁定（2026-10-09）：以03f0744为起点，正式默认/候选透明回调各一独立进程、同一新构建和60s素材，均drained ACK后等待2s再直接stop，复用分段时间与4份heap。候选必须2812 rendered+1 playedBack且至intervened不回退；旧版默认12.15s只作历史背景，不与新候选混比。原门限不变、无事后性能阈值。若heap超时，保留失败后至多一次同身份完整复测，不能反复重试凑通过。


### 后续路径：默认/候选同步stop同版本对照（2026-10-09）

- [x] 正式两独立进程、同源码/二进制/60s素材，透明回调且均等待2s；默认2813played，候选2812rendered+1played，候选至intervened无回退。
- [x] 两组2/2、8/8heap有效；默认stop10.895413s、候选0.053060s，仅单次路径观察，不冒充一般上界或统计收益。
- [x] EOF/图/关闭后两点资源与事件检查通过；定向4/4、工具56/56、夹具4/4、发现678/663，独立复审无P1/P2，157份文件归档。
- [x] 同一session在自然EOF并停止原生player后seek到起点/中段再播放，默认和候选均已验证；发现并修复显示节拍恢复缺口，见后续记录。

无生产修改，无完整native/iOS/长程重跑。见[协议](../../../tool/playback_benchmark/decoded-stop-paths-protocol.md)、[证据](../../../tool/playback_benchmark/macos-stop-paths-observations.json)与[报告](../reports/2026-09-26-remaining-08-performance-release.md)。准入与整体有界仍false。


### 后续恢复：EOF停止后的同会话seek/重播（2026-10-09，base195e0d4）

- [x] 两条真实默认/候选路径各三轮：首次播放、EOF+stop后seek0、再次EOF+stop后seek2000；始终同host/session/output及节点集合。
- [x] 首次原生2/2失败：音频sample继续增加，但公开位置停在0/2156ms，完成数始终1。保留失败附件和源码，不计通过。
- [x] 根因是自然EOF暂停display ticks，play未恢复；在共享play成功路径恢复既有display，不重建音频、不自动stop、不启用候选。
- [x] 修复后定向4/4、0跳过；默认/候选完成数1→2→3，视频帧97→193→241，sample/公开位置推进；首帧每session一次，实际提交模式和候选anchor持续成立。
- [x] 原代真实完成回调在seek后暂停/播放中/重复close后注入；无提前完成/错误/迟到发布，关闭后账本0、engine停止、player脱离。镜像/夹具4/4，发现iOS678/macOS665，复审无P1/P2。
- [x] 已收敛EOF回收策略与候选剩余准入矩阵，见下方当前入口；本项是决策文档完成，不是候选准入通过。

执行裁定：已有失败证明共享重播缺陷，因此本轮从测试扩展到最小生产修复。定向4项覆盖故障和相邻自然EOF/尾部暂停语义，不重复完整原生/音频套件；共享iOS路径本轮未运行。仅4.021s本地AVC/AAC，不是长程、延迟或heap实验；为注入而有界保留一个完成闭包，不提供内存归因证据。见[协议](../../../tool/playback_benchmark/decoded-stop-replay-protocol.md)、[24份原始证据](../../../tool/playback_benchmark/macos-stop-replay-observations.json)与[P08报告](../reports/2026-09-26-remaining-08-performance-release.md)。候选默认/正式准入/整体有界仍false。


### 当前入口：EOF回收策略与剩余准入矩阵（2026-10-09，base bcd547b）

- [x] 核对现有源码与原始归档，明确自然EOF只暂停presentation时钟/显示节拍，不把测试手动暂停/stop当生产行为。
- [x] 保留现有EOF流程；不增加同步/后台自动stop，不启用候选；既有显式控制与失效重载语义不变。
- [x] 将九类门槛映射到证据、版本范围及缺口；历史1201.179s通过、完整658项与当前定向4项分开，发现665不冒充当前完整通过。
- [x] 后续工作收敛为R1恢复行为、R2生命周期资源、R3资源准入结论、R4设备/平台、R5最终版本回归；外部资源缺口不阻塞本机可执行项。
- [x] R1自然EOF后不注入原生stop的seek/重播与Host后台恢复已验证，默认/候选均覆盖，见下方记录。

唯一当前矩阵：[EOF回收与候选准入](../reports/2026-10-09-audio-eof-admission.md)。旧章节的“下一项”是历史记录，以此入口为准。此次仅文档/源码与证据核查，无新原生/heap/长程运行，不修改生产；完整P08及候选准入仍开放。


### R1：正常EOF重播与Host生命周期恢复（2026-10-09，base c98daef）

- [x] 新增默认/候选无手动stop的三轮播放，覆盖seek0/2000、真实音频sample/公开位置/视频推进、完成1/2/3及首帧一次；共用helper保留手动stop对照，非stop记录manualStop=false/stopSeconds=null。
- [x] 新增默认/候选EOF后重复suspend/resume：遵守既有Host契约，同session释放旧图并重建一次output，不强迫旧节点跨后台存活；完成态不自动重播。
- [x] 旧完成回调在暂停、播放及close后注入；显式seek0/play能恢复，重复close和close后resume不产生晚到公开事件/纹理；释放后ledger0、所有engine停止/player脱离。
- [x] 六项原生首次6/6、0跳过，夹具4/4、发现iOS678/macOS669，独立复审无P1/P2；18份原始证据及最终source/binaryhash归档，未修改生产。
- [x] R2固定协议及默认/候选重复生命周期资源观察完成，见下方记录；测量完成不等于整体有界。

范围仅4.021s本地AVC/AAC和直接Host生命周期调用，不证明实际OS后台、设备路由、物理音画或长程/整体资源边界。没有重跑完整native或iOS。见[协议](../../../tool/playback_benchmark/decoded-eof-lifecycle-protocol.md)、[原始归档](../../../tool/playback_benchmark/macos-eof-lifecycle-observations.json)及[当前准入矩阵](../reports/2026-10-09-audio-eof-admission.md)。候选默认、正式准入、整体有界仍false。


### R2：六轮seek/replay与独立host Load/close（2026-10-09，base1cc539e）

- [x] 执行前冻结四独立进程×6轮、5个heap阶段、原8s heap/30s ACK/180s native/240s parent限制；后EOF原生pause采样干预与生产行为分开。
- [x] 复审P2冻结计数缺陷已以原生RED6断言→GREEN修复，实时标量sink/纹理观察不保留旧graph；初始通过不冒充正式证据。
- [x] 最终原生2/2（四配置门禁）、正式4/4、20/20heap、工具5/5、夹具4/4；发现678/671。首次候选seek两份heap超时保留，仅一次同身份/同门限完整复测通过，生产未改。
- [x] 四组实际模式/完成/首帧/资源和图释放通过；总堆正负差额及类型缺失null如实保留，407份原始文件可离线复核。
- [x] R3资源决策完成：当前不准入，A5仍未通过；理由与重新评估条件见下方及当前矩阵。

见[协议](../../../tool/playback_benchmark/decoded-lifecycle-resources-protocol.md)、[证据](../../../tool/playback_benchmark/macos-lifecycle-resources-observations.json)、[P08数值报告](../reports/2026-09-26-remaining-08-performance-release.md)。Load-close为每轮独立host，非同host替换Load；当前仅短素材与采样干预结果，非长程/物理输出/整体有界。候选关闭。


### R3：资源准入结论（2026-10-09，base b4f0277）

- [x] 分别核对长度矩阵、类型归因、历史断供模型、同版本stop及R2六轮证据，保留各自构建与采样边界，不做跨版本收益比较。
- [x] 明确不准入：本所有者预算不能约束通知后系统保留；兼容回退仍可达；短序列总堆增长尚无可验证累计上限。三个启用/准入/整体有界标志保持false。
- [x] 说明重新评估所需工作集契约，以及安全边界重建/容量可解释输出后端的设计代价；本轮不改架构，不重复无目标采样。
- [x] R4本机盘点与共享iOS模拟器验证已完成，见下方；设备格仍开放，R4/R5通过不自动关闭资源门槛A5。

[当前决策与详细证据](../reports/2026-10-09-audio-eof-admission.md)。本轮仅文档核查，无新运行通过声明、生产修改或默认启用；R3交付完成不表示P08或资源问题解决。


### R4：本机盘点与可执行兼容检查（2026-10-09，base 6bc2bf3）

- [x] 14次只读查询及脱敏归档：M1/macOS27.0.1、内置44.1kHz输入/输出、两个显示器、三个iOS27模拟器和一个可见iPhone16；Runner目标可选。保留沙箱服务错误，不把空列表当设备不存在。
- [x] 用户确认暂时无额外设备，先完成本机可执行验证；最低OS/Intel、第二音频路由、校准物理音画条件单列缺口。
- [x] 初轮iOS 673通过/1失败/3跳过；677规范身份全部出现（源码678含一项macOS-only）。RTMP恢复测试固定150ms等待误判，以300ms测试延迟定向RED重现，再改为原2s期限内等待真实创建；生产代码未改。
- [x] 最终iOS 674通过/0失败/3条件跳过，规范677项及原跳过证据全部校验；macOS受影响4/4，夹具4/4，发现678/671。375冻结文件匹配，81份测试原始/脱敏记录可核对，初轮/RED保留。
- [ ] R4实际路由、物理音画、macOS12/Intel/iOS15及当前物理iOS运行：仅对应设备格待补，不计通过。
- [ ] 下一项R5本机验收：冻结最终身份并完成完整macOS原生清单、无heap短门禁与>=1200s长播，整理发布结论；身份不变时复用R4 iOS证据，资源A5仍不准入。

[当前矩阵](../reports/2026-10-09-audio-eof-admission.md)、[盘点](../../../tool/playback_benchmark/apple-device-inventory-observations.json)、[协议](../../../tool/playback_benchmark/apple-platform-inventory-protocol.md)、[测试证据](../../../tool/playback_benchmark/apple-local-platform-validation-observations.json)。未切换系统设备/采样率或安装真机应用，未提高部署下限，未启用候选。完整P08仍未完成。


### R5：首轮完整回归与失败保留

- [x] 完整macOS规范670项逐身份匹配，667通过/3失败/0跳过；R4相关375哈希一致，复用iOS历史674通过/3跳过。
- [x] 纠正执行器误用默认60s预算的两项矩阵测试：相同二进制180s定向2/2、0跳过；初轮失败保留，不计新的全套通过。
- [x] 归档30.024849s连续性失败：活动drop5（catchUp4+lateAfterCapacity1），关闭后另增1；约154–160ms调度窗口，根因尚未定位。
- [ ] 调度延迟归因、当前完整套件通过、独立短门禁及>=1200s长播仍待完成；本轮未启动短/长播。

下一项是有界调度延迟归因，随后重新评估R5前置条件；不盲目重跑。后续iOS优先iPhone18，具体可用型号执行前确认。见[当前记录](../reports/2026-10-09-audio-eof-admission.md)；候选关闭，P08仍开放。


### R5后续：调度时序诊断已接入，根因仍开放

- [x] 测试专用tick间隔/工作时间、单待处理主队列探针及后台间隔记录，32条标量历史，默认关闭、stop隔离；生产不改。
- [x] 原生RED→GREEN2/2，工具204/204、夹具4/4，发现678/673；带探针短播不能作为普通长播门禁。
- [x] 一次诊断30.027486s、原生1/1，播放drop/order0；tick work最大2.710ms、gap33.920ms；136.453ms主队列事件发生在首个playing采样之前。94份归档、178源码/5二进制hash保持一致。
- [ ] 原活动drop5原因未定位；下一项在正确180s预算的完整套件上下文启用同一诊断，保留失败、不盲目重试，之后仍需独立无探针短/长门禁。

后续iOS优先 **iPhone 18 Pro Max** 已明确。详见[当前记录](../reports/2026-10-09-audio-eof-admission.md)；R5、A5及设备格仍开放。


### R5最终回归、复审修正及长播失败保留

- [x] 正确预算完整上下文诊断672/672，原5帧失败未复现，不宣称根因修复。
- [x] 唯一复审P2迟到首次提交锚点覆盖暂停位置：真实交错RED1失败/1对照通过→两类GREEN67/67；普通同步锚点不变。
- [x] 最终Pro Max679规范项：676通过、3原硬件条件跳过；macOS674/674。MCP300s等待超时保留，同一底层iOS运行继续成功，无重跑。
- [x] 同身份无探针30.030762s短门禁通过，原进度/零drop/order/时钟/模式/释放门限成立。
- [x] long失败前缀、失败后线程采样和一次有界时序诊断分别归档；418原始记录及最终身份核对，保持不准入。
- [ ] R5当前>=1200s长播未通过：原无探针9帧/199.375ms落后；诊断活动drop与64.599ms tickGap相关，根因未证明。下一项补齐回调入口及refreshCadence区间证据，不无变化重跑。
- [ ] A5整体资源边界和R4设备/物理输出格仍开放，完整P08未关闭。

详见[当前R5记录及准入矩阵](../reports/2026-10-09-audio-eof-admission.md)、[失败后诊断协议](../../../tool/playback_benchmark/display-stall-followup-protocol.md)与[原始归档](../../../tool/playback_benchmark/apple-audio-final-local-observations.json)。

### R5显示回调边界与长播环境修正（2026-10-10，base 2235024）

- [x] 补齐原生cadence入口、refresh、body及主运行循环活动的有界、默认关闭诊断。120.106s/310.398s均未复现活动drop；所见慢间隔位于回调进入之前，原55s丢帧的具体根因仍未证明。
- [x] 实测发现并修正唤醒工具240s到期缺陷；保护跟随owned进程生命周期，跨240s仍有效，退出无残留，不修改系统睡眠设置。
- [x] 保留首次全套674/1/0；修正EOF观察等待内部状态而未等公开异步回调的竞态，原期限及恰好一次断言不变。定向1/1后新完整套件675/675，零跳过，462源码/5二进制身份保持。
- [x] 新同版本无探针short30.029463s、770帧、活动drop/order0、最大落后23.125ms，释放检查通过。关闭阶段额外enqueueTimeout1单列。
- [x] 同版本无探针长播已通过：1201.167654s、28,915帧，活动drop/order0，最大落后48.250ms，关闭后释放检查通过；同一462项输入/5份二进制身份核对一致。

详见[显示调度记录](../reports/2026-10-10-display-cadence-latency.md)。A5不准入、R4设备条件和原失败根因仍保持各自边界；不把局部验证当作完整P08完成。
