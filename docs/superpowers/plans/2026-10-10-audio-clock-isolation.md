# 音频引擎时钟阻塞隔离 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking. 用户已选定当前任务内连续执行，保留该方式，不再询问执行方式；本计划书面审阅完成后开始实施。

**Goal:** 解除macOS定时视频worker对AVAudioEngine同步读锁的依赖，并以真实输出、生命周期和20分钟长播判定本机是否通过。

**Architecture:** 保留原生音频位置/host时间配对，通过renderer归一化成带区间、generation与rate的观测。YlMediaClock仅在候选路径拥有一个有界后台采样器，逐帧查询读取快照；控制变更立即撤销旧发布权限，过期明确停供与失败。

**Tech Stack:** Swift、AVFAudio、CoreMedia、XCTest、现有Flutter macOS宿主、Python验收与可移植证据。

**Spec:** [已获用户ok确认的设计](../specs/2026-10-10-audio-clock-isolation-design.md)。基线设计提交`c0d991c`；工作区还有上一轮已验证但未提交的诊断改动，不得丢弃或误称本计划新增。

## Global Constraints

- 候选默认关闭；无商业SDK；macOS最低12，定时候选仍需14，真实系统指标/暂停像素验收需14.4。
- 仅已启用macOS managed本地有限、非bounded定时显示候选接入；iOS、旧显示路径、直播、AVPlayer默认行为不变。
- 每会话一个串行采样者、一个10ms合并timer、一个快照槽；seek不创建新采样者。
- 快照自采样完成起最多100ms有效，当前host与原生观测host距离也不得超过100ms。
- 50ms/3帧窗口和既有100ms验收门限不放宽；过期事件非零不得判长播通过。
- 不持有session或快照锁调用原生读数；不在main/视频队列同步等待采样完成。
- 保留所有失败及源/二进制身份；性能manifest单独移除RPAC并验证实际未加载，日常检查不全局关闭。
- 后续iOS测试优先iPhone18 Pro Max。A5系统资源上界与R4物理音画验收仍开放。

## Review Focus

1. 原生host在未来：必须使用带符号差值，不能把提前样本当作当前已呈现位置；Task 1/2字面量测试。
2. 控制命令发生在原生读取阻塞期间：暂停、seek、变速、close后旧读数不能复活播放；Task 2/3屏障测试。
3. 音频暂不可读与真正EOF不同：只有输入结束且播放排空才能进入视频尾部host回退；Task 1/3测试。
4. 采样迟到或不断返回旧时间戳：完成时间新鲜不能替代观测时间新鲜；Task 2双有效期测试、Task 4门禁测试。
5. 相邻音频块入队/完成改变归一化基准：旧raw读数不得与更新后的playedPosition拼接；Task 1竞争测试。

## 文件与执行命令

下文`N`指`packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple`；`T`指`packages/yl_player/example/macos/RunnerTests`；`M`指`tool/consumer_fixtures/apple_flutter/RunnerTests-macos`。所有测试变动同步T/M；更新`tool/consumer_fixtures/apple_flutter/main_example_tests.py`发现数，不修改历史固定清单。

新增`N/Shared/Clock/YlAudioClockObservation.swift`负责值和时间换算；新增`N/Shared/Clock/YlIsolatedAudioClock.swift`负责采样、许可与快照。现有AudioRenderer只增加原生时间戳和观测出口，不拆解无关解码逻辑。现有MediaClock负责候选委托及旧路径兼容。

每组RED/GREEN使用不同结果目录，以保存失败：

```sh
python3 -B tool/run_with_display_awake.py xcodebuild test -quiet \
  -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner \
  -configuration Debug -derivedDataPath packages/yl_player/example/build/native-macos-tests \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES \
  -only-testing:RunnerTests/YlMacosPresentationTests \
  -resultBundlePath /private/tmp/yl-clock-task2-red.xcresult
```

Task 1测试属于`YlMacosAudioTests`，将only-testing改成该类中的新增方法。首次编译失败后加最小类型骨架，再确认语义断言RED；不能把缺类型错误当根因已复现。每步结束运行相关测试；最后集中完整macOS回归一次，不每个小改动重跑全套或长播。

### Task 1: 原生音频时间配对与归一化观测

**Files:** 新建`N/Shared/Clock/YlAudioClockObservation.swift`；修改`N/Shared/Clock/YlMediaClock.swift`中的YlRenderedAudioTime、`N/Shared/Audio/YlAudioRenderer.swift`、`N/Shared/Audio/YlAudioPipeline.swift`的Resource转发；测试`T/YlMacosAudioTests.swift`及M镜像。

**Interfaces:**

```swift
// YlRenderedAudioTime保留原有调用兼容：显式init第三参数默认nil。
init(sampleTime: Int64, sampleRate: Double, hostTimeUs: Int64? = nil)
struct YlAudioClockSample {
  let generation: UInt64
  let positionUs: Int64
  let hostTimeUs: Int64
  let lowerBoundUs: Int64
  let upperBoundUs: Int64
  let rate: Double
  func position(atHostTimeUs: Int64) -> Int64?
}
enum YlAudioClockObservation {
  case running(YlAudioClockSample)
  case silence(YlAudioClockSample)
  case waiting
  case paused(positionUs: Int64)
  case ended(positionUs: Int64, hostTimeUs: Int64)
  case invalid
}
// renderer与Resource均提供；系统查询只允许采样者调用此新增出口。
func clockObservation(expectedGeneration: UInt64) -> YlAudioClockObservation
```

- [x] 写字面量测试`testTimestampedAudioUsesSignedHostDelta`：sample position=1_020_000、host=1_020_000、区间[1_000_000,1_100_000]、rate1；host1_000_000应返回1_000_000，host1_040_000应返回1_040_000；rate2时后者返回1_060_000。测试区间钳制、NaN、Infinity、非法区间、Int64极值，所有非法值返回nil而非trap。
- [x] 写`testAudioObservationRejectsReadAcrossReset`和`testAudioObservationDoesNotPairOldRawWithNewPlayedPosition`。使用已有output替身，在renderedAudioTime出口设置进入/释放信号量；只阻塞外部读数，不替换renderer逻辑。读取期间reset或推进完成回调，返回后必须invalid/waiting，不得发布混合时间点。
- [x] 写`testAudioObservationDistinguishesWaitingPausedAndEnded`：有未完成PCM时原生nil不能ended；pause应paused；仅finishInput并完成所有真实pending回调后才ended；播放中时钟缺host或非有限sampleRate必须invalid。
- [x] 运行上述RED。原生读取补充有效host：先验证nodeTime/playerTime的host有效性，再用`AVAudioTime.seconds(forHostTime:)`转换并检查有限性与Int64范围。不得用函数返回时刻冒充host。
- [x] 实现`clockObservation`：在renderer锁内拍下completionGeneration、控制版本、generation、renderAnchor、playedPosition与区间，释放锁后读原生，重入锁确认这些影响映射的状态仍可用；不一致直接丢弃。原生位置按当前renderAnchor映射，未解释的回退不能与最新playedPosition强行max后沿用旧host。silence只来自已执行的advanceSilence及其明确host/区间；不是nil回退。
- [x] 对pause、rate、flush、reset、dispose、设备失效递增观测控制版本；入队基准变化/区间撤销参与读取前后校验。既有renderedAudioTime和默认媒体时钟语义不改。
- [x] GREEN上述测试并运行相关现有音频时钟/欠载/暂停/完成用例；同步镜像、发现数。提交`feat: preserve timestamped audio clock observations`。

### Task 2: 单采样者、快照有效期与控制撤销

**Files:** 新建`N/Shared/Clock/YlIsolatedAudioClock.swift`；测试`T/YlMacosPresentationTests.swift`及M镜像。

**Interfaces:** 消费Task 1 observation，产生以下内部对象；生产计时与测试计时均经注入闭包，不向生产类加入仅用于测试的手动tick方法。

```swift
struct YlIsolatedAudioClockStatistics {
  var samples: Int
  var staleEvents: Int
  var rejectedObservations: Int
  var maximumReadSeconds: Double
  var maximumAgeSeconds: Double
}
final class YlIsolatedAudioClock {
  init(read: @escaping (UInt64) -> YlAudioClockObservation,
       hostTimeUs: @escaping () -> Int64,
       queue: DispatchQueue)
  func configure(generation: UInt64, positionUs: Int64, rate: Double, playing: Bool)
  func invalidate() // 立即废止发布许可，保留冻结位置
  func snapshot(atHostTimeUs: Int64) -> YlPresentationClockSnapshot
  var statistics: YlIsolatedAudioClockStatistics { get }
  func stop() // 不join被阻塞的采样队列
}
```

- [x] 写`testIsolatedClockSuppliesWhileAudioReadIsBlocked`：第一次返回有效样本；第二次read在信号量处阻塞。测试线程使用可控host值读快照，断言位置按已发布配对推进且读取不等待读者；100ms内视频worker仍投递已就绪帧。通过屏障确认read确实未返回。
- [x] 写`testIsolatedClockExpiresWithoutHostFallback`：sample/receipt host均1_000_000，snapshot在1_050_000有效，在1_100_001过期；过期playing=false且位置冻结，重复读取不继续走时；同一过期段计一次事件。新鲜样本恢复后计数不能归零。
- [x] 写`testRepeatedOldObservationCannotRenewFreshness`：receipt不断更新、source host不变，超过source100ms必须过期；未来host1_020_000在now1_000_000仍按负差，超出100ms未来必须拒绝。
- [x] 写`testBlockedSampleCannotSurviveControlVersionChange`，在同一阻塞点分别执行pause、configure新generation、rate2和stop。晚到结果不能覆盖新状态；seek100次仍最多一个read在途，不创建替代采样者；stop不等待release即可撤销。
- [x] RED后实现：timer直接在唯一串行queue执行read，唤醒只用一个pending位；槽锁仅保护标量与许可。每次read记录开始generation/version，返回后匹配再发布。configure/invalidate/stop同步递增version；控制状态无需等待原生系统调用。

```swift
let permit = lock.withLock { (generation, version, stopped) }
guard !permit.2 else { return }
let observation = read(permit.0) // 锁外，仅此串行路径调用
lock.withLock {
  guard !stopped, generation == permit.0, version == permit.1 else {
    statisticsValue.rejectedObservations += 1
    return
  }
  // 验证并替换唯一观测槽；不追加历史payload或系统任务。
}
```

- [x] 快照只在有效观测、匹配rate/generation及播放许可下playing=true；等待/过期返回冻结快照。媒体位置先按带符号差换算再受音频区间约束。真实ended使用明确端点建立视频尾部host锚，waiting不能触发。暂停读取不产生过期事件；播放启动等待超过100ms产生一次事件。
- [x] GREEN整个presentation套件，确认既有50ms/3帧窗口、pause/seek/EOF用例未受影响；提交`feat: isolate blocking audio clock sampling`。

### Task 3: 接入媒体时钟、视频worker和会话生命周期

**Files:** 修改`N/Shared/Clock/YlMediaClock.swift`、`YlPresentationCoordinator.swift`、`YlTimedVideoPump.swift`；`N/Shared/Session/YlManagedPlaybackSession.swift`；`N/Shared/Audio/YlAudioPipeline.swift`；测试T/M的presentation和audio文件。

**Interfaces:**

```swift
// MediaClock拥有候选采样器；读/控制统一经此对象，避免两套独立走时。
func enableIsolatedAudioClock(read: @escaping (UInt64) -> YlAudioClockObservation,
                             generation: UInt64)
func invalidateIsolatedAudioClock()
func setAudioClockGeneration(_ generation: UInt64)
func stopIsolatedAudioClock()
var isolatedAudioClockStatistics: YlIsolatedAudioClockStatistics? { get }
// 现有position/presentationSnapshot/play/pause/seek/setRate签名保持。
```

- [x] 写`testCandidatePositionAndWorkerNeverReadNativeAudioSynchronously`：候选采样read阻塞，同时在main和worker请求position/snapshot；两者必须从缓存返回。旧路径未启用时仍走既有audioTime闭包，不能让旧行为测试默默使用新路径。
- [x] 写`testCandidatePauseRevokesBeforeNativePauseCompletes`：native pause延迟，命令入口先invalidate；worker立即停供，晚到read不能恢复。rate与seek同类测试，失败的原生操作不能重新打开旧播放许可。
- [x] 写`testCandidateClockEOFAndSilenceRemainDistinct`：音频先结束、视频先结束、欠载后补包、静音跨度、无音轨；无音轨继续既有host时钟，不强行等待不存在的音频采样。
- [x] RED后接入。session按已有候选条件与选中音轨安装采样闭包；闭包弱捕获session，先取Resource再放开session锁，调用`clockObservation(expectedGeneration:)`。MediaClock候选读数只委托sampler，旧状态逻辑仅服务旧路径和无音轨。
- [x] 所有进入实际音频pause/rate/reset的控制入口先撤销快照，成功后按新状态configure；失败保留失效并沿用现有错误路径。seek/flush更新generation，不能创建新sampler。设备变化即撤销并保留音频错误。stop/dispose取消sampler，不在session锁中等待read。
- [x] `YlTimedVideoPump`接收过期/等待返回的冻结快照，只更新rate0与停止投递；正常paused仍原语义。timer不能因clock暂不可用而永久停掉：区分用户暂停与临时时钟失效，或由新快照发布合并唤醒。新增内部快照状态字段必须有默认值以兼容旧构造。
- [x] 单列clock统计，不能拿worker空档变小证明音频时间新鲜。GREEN受影响套件并运行真实250ms main阻塞、pause/seek/EOF/close用例。提交`fix: remove native audio reads from timed video pacing`。

### Task 4: 真实时钟与失败门禁

**Files:** T/M `YlMacosAudioTests.swift`；`tool/playback_benchmark/collect_timed_video.py`、`test_collect_timed_video.py`、`run_timed_video_activation.py`、`test_run_timed_video_activation.py`、`timed-video-protocol.md`。

**Interfaces:** 每行新增`audioClock`，包含`required`、`isolated`和Task 2统计。无音轨明确required=false；有音轨required=true时，缺字段、未隔离、无采样、非有限计数、过期次数非零均失败。历史记录使用原归档版本复算，不能替历史缺字段补true/0。

- [x] 写collector RED：在有效observation的初末行中设置`audioClock={required:true,isolated:false}`、缺samples、staleEvents=1或maximumAgeSeconds>0.1，必须失败；不得因systemDropped=0而绕过。
- [x] 实现严格校验并更新真实测试落盘。来源为实际sampler统计，不用测试中的常数作隔离证明。性能配置继续运行时验证RPAC未加载。
- [x] 写真实AVAudioEngine时钟测试覆盖rate0.25/1/2/4、pause/resume、reset后读数及停止后不可用。确认host域转换和合法future时间，不通过扩大100ms接受异常值。
- [x] 运行Python collector/runner及真实原生测试。保持sampler诊断开关前后算法相同，测试过期故障会使整次验收失败。提交`test: gate timed playback on fresh isolated audio clocks`。

### Task 5: 集中验收、长播与结论

**Files:** 新报告`docs/superpowers/reports/2026-10-10-audio-clock-isolation-acceptance.md`、新证据`tool/playback_benchmark/macos-audio-clock-isolation-observations.json`；更新本计划与现有followup报告的状态链接，不覆盖旧失败。

- [x] 运行完整macOS原生回归一次，导出准确通过/失败/跳过及源身份；若任何共享默认逻辑改变，运行iPhone18 Pro Max对应回归。新增测试发现数和镜像检查通过。执行一次全分支最终审查，按executing-plans技能处理重要问题，修复后重跑受影响测试。
- [x] 构建Profile测试产物：

```sh
python3 -B tool/run_with_display_awake.py xcodebuild build-for-testing -quiet \
  -workspace packages/yl_player/example/macos/Runner.xcworkspace -scheme Runner \
  -configuration Profile -derivedDataPath /private/tmp/yl-clock-isolation-profile \
  -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES
```

- [x] 固定媒体和外部10s激活请求，运行一次短测：

```sh
python3 -B tool/playback_benchmark/run_timed_video_activation.py \
  --products /private/tmp/yl-clock-isolation-profile/Build/Products --configuration Profile \
  --directory /private/tmp/yl-clock-isolation-short --candidate --without-thread-checker
```

- [x] 短测所有门禁通过后冻结源码及二进制；检查当前窗口/机器负载，不自动关闭其他应用或非本轮模拟器。按同一命令增加`--long`，目录改为`/private/tmp/yl-clock-isolation-long`，一次20分钟。正式测量期间不并行构建、采样栈或修改哈希覆盖源码。
- [x] 核对活动系统/应用零新增丢帧、无过期、正常worker空档、暂停像素、disposed两次ledger0、native退出0及owned PID退出。任何异常保留原始结果，记录精确失败区间；继续定位必须有新的假设和对应验证，不能无依据重复长播直到通过。
- [x] 归档每次RED/GREEN、原生结果、运行manifest、源码/二进制身份、激活与退出回执、采样统计；逐条解码校验SHA-256，离线复算门禁与报告数字。
- [x] 报告区分“阻塞隔离行为成立”“本机真实显示长播结果”“A5/R4仍开放”。未达到门禁保持不准入；即使通过也不自动打开生产默认。提交`test: record audio clock isolation acceptance`，不push。

## 计划自检

Task 1提供原生配对和明确状态，Task 2提供有界采样与撤销，Task 3统一候选媒体时钟与控制入口，Task 4让过期无法伪装成通过，Task 5完成真实输出和退出验证。五项Review Focus分别由列出的具名测试覆盖。已保留用户当前任务内执行方式；计划已获确认并执行完毕；最终712项macOS回归通过，完整20分钟严格验收因系统丢4帧失败，候选保持不准入。详见[验收报告](../reports/2026-10-10-audio-clock-isolation-acceptance.md)。复选框表示步骤已执行，不表示失败门禁改判通过。
