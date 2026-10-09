# Apple 音频最终尾部候选接入 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行执行方式；本计划不自动启动子代理。

**Goal:** 将已验证的工具策略接入默认关闭的 macOS 本地有限点播测试路径，验证真实 renderer、账本、媒体时钟和控制操作，形成可审计的生产准入结论。

**Architecture:** 普通 PCM 按真实 rendered 通知退还本所有者资源，保留一块计费的真实尾部，EOF 由尾部 playedBack 表示最终播放边界。复用转换器已有 reservation，分开资源数量、已提交时间范围与输出排空；100ms 连续尾部等待触发单向兼容回退。生产默认继续使用逐缓冲 playedBack，直到独立验收完成。

**Tech Stack:** Swift、AVFAudio、现有 FFmpeg bridge、XCTest、Python unittest；macOS 原生消费工程与镜像夹具。

**Spec:** [输出完成契约 §10](../specs/2026-10-08-audio-output-completion-contract.md)、[需求基线](../specs/2026-09-20-playback-expansion-requirements.md)、[P08](2026-09-26-remaining-08-performance-release.md)。

起点 `9c5967a`。Task 1–4 已实现并验证；Task 5 尚未执行。既有工具通过不能替代生产验收。

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

- [ ] 在真实运行之前冻结素材哈希、源码/编译身份、系统设备/路由、电源/热状态、同条件 legacy/candidate 对照、计划数量与失败保留规则。最小集：0/1/3/2000 PCM、300ms 断供、在途 pause/EOF、seek/切轨/rate/graph invalidation；真实 converter 与 session 必须各有记录，不能只运行工具模型。
- [ ] 新增实际 adapter 的节点 tap 回归，检查所有输入帧只交付一次且顺序正确；沿用工具的有限短序列 Float32 marker，第一声道 tap 与最终 mixer 静音必须标明。正常 2000 块零内部零帧；断供组完整保留 gap 并验证单向回退，不称连续无间断。记录提交/回调 mode、generation、时钟锚点及 ledger 峰值；EOF 只在最终通知/资源清空后出现。
- [ ] 用 fake callback 丢失及旧 generation 通知确认不会伪造 completed；用真实故障记录现有安全错误字段，不记录 URL/headers/原生异常原文到公开诊断。
- [ ] 运行一次完整 macOS 原生套件与实际发现检查，保留 xcresult 身份、失败与跳过；共享代码需要 iOS 编译检查，未运行的 iOS/最低系统/Intel 行明确未验收。只有工具校验器改动时才运行对应 Python 回归，不因文档变更重跑全套。
- [ ] 独立冻结并执行同会话至少 1200s 的无 MSL、播放中无 heap 连续性观察；另开资源取证运行，不能把 heap 干扰组算作连续性通过。复用 P08 已冻结进度/失败规则，记录 RSS/footprint/owned PCM/回调外壳与 timer 的前中后变化和释放后值；协议在执行前写清新增指标的阈值依据，不能事后以观测最大值定合格线。若下游总体边界证据仍不足，保留 `downstreamBoundProven=false`，输出资源变化原值。
- [ ] 分开汇总：定向行为、真实节点、长播连续性、独立资源、物理音画、设备/最低 OS。兼容回退恢复逐缓冲对象保留是已知限制，不能从稳态组外推所有来源。缺设备或物理证据记录具体缺口，继续能完成的范围。
- [ ] 提交 `test: validate gated audio terminal integration`。这五项完成只代表测试适配与证据完成；默认启用需另一个有明确支持矩阵与资源/音画结论的发布切片。完整 P08 Task 1/2 不随本子计划自动勾选。

## 自审与交付边界

2026-10-08 文档自审：准入与 bounded 排除→Task 1/4；通知来源→Task 2；既有 token/所有权与输出排空→Task 3；时钟/控制/定时器→Task 4；独立长播及未准入状态→Task 5。新接口均由前序任务定义，默认 factory 签名保持不变；测试路径按仓库实际镜像核查。历史 §4/7 的否决不被新计划改写。

规划提交 `184531f` 只包含文档。后续 Task 1–4 已完成下述接口与验证，下一执行项为 Task 5；沿用用户已授权的本会话实现与本地提交，不推送远端。

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
