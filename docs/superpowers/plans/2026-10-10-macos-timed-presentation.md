# macOS定时显示候选 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 沿用当前任务内执行方式；不按任务启动子代理，不重复询问是否继续。

**Goal:** 在已附着原生视图的macOS managed本地有限播放中，以默认关闭的定时显示候选解除逐帧投递对main的依赖，并验证真实输出。

**Architecture:** 解码队列保留原有预算，独立worker使用媒体时钟快照按序向可撤销的lease endpoint提交带PTS样本。main继续处理视图与状态事件；endpoint在worker上独占sampleBufferRenderer，控制命令和flush通过epoch隔离。

**Tech Stack:** Swift、CoreMedia、AVFoundation、AppKit、现有Flutter/FFmpeg/VideoToolbox桥接、XCTest、Python证据复算。

**Spec:** [已获用户确认的设计](../specs/2026-10-10-macos-timed-presentation-design.md)。

状态：用户于2026-10-10确认“确认计划，连续执行”；Task 1–5均未开始。原路径Debug和Profile失败基线已具备，但真实原生层的失败验证尚需Task 4补齐。

## Global Constraints

- 不用商业SDK；macOS最低版本仍为12；先完成本机可执行验证；后续iOS测试优先iPhone18 Pro Max。
- 候选仅macOS14+、managed本地有限文件、普通非bounded缓冲、已附着原生视图；默认false，仅内部测试注入，不增加用户设置。
- macOS12/13、iOS、Flutter纹理、AVPlayer、直播与bounded模式保持旧路径；不能称这些路径已修复。
- 最多提前50ms墙钟时间、最多3个尚未到期样本、worker唤醒周期上限10ms；不扩大既有字节预算。
- 不设置DisplayImmediately于定时样本，不混用layer和sampleBufferRenderer入队接口，不绕过lease，不把提交当显示。
- 音频候选defaultEnabled、productionAdmission和downstreamBoundProven保持false；A5/R4保持开放。
- 每项先失败验证再实现；相关检查集中执行，只有新问题才扩大测试；失败记录保留，不无改动重跑长播。

## Review Focus

- 异常PTS、重复PTS、极高rate与音频时间回退不能使提前窗口溢出或绕过3帧限制（Task 1）。
- 候选在commit前提交、旧flush在新lease后完成不能污染画面或新错误接收者（Task 2）。
- renderer长期不ready、pause/close与worker同刻发生不能无界重试或锁反转（Task 3）。
- enqueue有进展但系统没有显示、指标nil不能计作成功（Task 4）。
- 稳态通过但激活时worker也被饿死，必须单独记录而非改阈值；音频/视频尾部长度不等不能早报EOF（Task 3/5）。

## 文件约定与验证命令

源码目录`N=packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple`；以下`N/`均展开为该完整仓库路径。macOS测试修改现有`packages/yl_player/example/macos/RunnerTests/YlMacosPresentationTests.swift`，镜像为`tool/consumer_fixtures/apple_flutter/RunnerTests-macos/YlMacosPresentationTests.swift`；涉及解码观察的修改使用两处同目录`YlMacosAudioTests.swift`。新增Swift源由现有包自动发现，新增测试方法同步`tool/consumer_fixtures/apple_flutter/main_example_tests.py`实际发现登记。

相关原生验证使用以下命令；每次结果目录唯一，不覆盖失败产物。执行任务时将`<task>`替换为任务号与red/green阶段，不把尖括号传给shell。

```sh
python3 -B tool/run_with_display_awake.py xcodebuild test \
  CODE_SIGNING_ALLOWED=NO ENABLE_TESTABILITY=YES ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  -quiet -sdk macosx -workspace packages/yl_player/example/macos/Runner.xcworkspace \
  -scheme Runner -parallel-testing-enabled NO \
  -derivedDataPath packages/yl_player/example/build/native-macos-tests \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:RunnerTests/YlMacosPresentationTests \
  -resultBundlePath /private/tmp/yl-timed-<task>.xcresult
python3 -B tool/consumer_fixtures/apple_flutter/main_example_tests.py --current-only
git diff --check
```

Expected：RED只来自目标行为；编译错误须补齐最小接口后观察行为失败。GREEN目标原生测试全部通过，镜像/发现一致，diff无错误。Task 4/5切换only-testing到新增真实层与解码测试方法，避免每轮重复整个音频资源矩阵。

### Task 1: 有序投递窗口与一致时钟快照

**Files:** 新建`N/Shared/Clock/YlTimedVideoWindow.swift`；修改`N/Shared/Clock/YlFrameScheduler.swift`、`N/Shared/Clock/YlMediaClock.swift`、`N/Shared/Clock/YlPresentationCoordinator.swift`及上述presentation测试与镜像。

**Interfaces:**

```swift
struct YlPresentationClockSnapshot {
  let positionUs: Int64
  let hostTimeUs: Int64
  let rate: Double
  let playing: Bool
}
// YlMediaClock新增；在已有锁内读取全部状态，外部audioTime仍在锁外调用。
func presentationSnapshot(atHostTimeUs: Int64) -> YlPresentationClockSnapshot
// YlPresentationScheduling新增，默认返回nil以兼容已有替身。
func nextFrame(upTo positionUs: Int64, generation: UInt64) -> YlFrameEnvelope?
// 独立纯状态对象；owner只有worker，无系统调用。
final class YlTimedVideoWindow {
  func canSubmit(ptsUs: Int64, snapshot: YlPresentationClockSnapshot) -> Bool
  func didSubmit(_ frame: YlFrameEnvelope)
  func advance(to positionUs: Int64)
  func reset(generation: UInt64)
  var pendingFrames: [YlFrameEnvelope] { get }
}
```

- [ ] 写`testTimedWindowDoesNotExceedLeadOrCount`、`testTimedSchedulerDoesNotCatchUpFutureFrames`、`testTimedClockSnapshotPreservesPauseAndRate`。使用现有frame helper构造frame，新增窗口测试核心断言如下；frame创建沿用`YlFrameEnvelope(reservation:payload:ptsUs:durationUs:keyframe:generation:)`，payload用`NSObject()`即可。

```swift
let window = YlTimedVideoWindow()
window.reset(generation: 1)
let s = YlPresentationClockSnapshot(positionUs: 1_000_000, hostTimeUs: 10_000_000, rate: 1, playing: true)
XCTAssertTrue(window.canSubmit(ptsUs: 1_050_000, snapshot: s))
XCTAssertFalse(window.canSubmit(ptsUs: 1_050_001, snapshot: s))
for pts: Int64 in [1_010_000, 1_020_000, 1_030_000] {
  window.didSubmit(.init(payload: NSObject(), ptsUs: pts, durationUs: 10_000, keyframe: true, generation: 1))
}
XCTAssertFalse(window.canSubmit(ptsUs: 1_040_000, snapshot: s))
window.advance(to: 1_010_000)
XCTAssertTrue(window.canSubmit(ptsUs: 1_040_000, snapshot: s))
```

- [ ] 运行RED；额外覆盖PTS接近Int64.max、重复PTS、duration=0、rate 0.25/4、暂停与音频回退。不能出现整数trap、NaN转换或回退释放未来帧。
- [ ] 实现时钟一致快照、按序取最早帧、独立lastSubmittedPTS和窗口限制。以checked arithmetic计算`position + floor(50_000 * rate)`；溢出时饱和到Int64.max。旧`frame(at:)`和丢帧诊断语义保持。窗口释放应用引用不提前释放CMSampleBuffer持有的reservation。
- [ ] GREEN运行上述命令并检查旧调度/时钟测试，更新镜像与登记；提交`feat: add bounded timed video scheduling primitives`。

### Task 2: 可撤销的定时输出租约

**Files:** 新建`N/Shared/VideoToolbox/YlTimedVideoEndpoint.swift`；修改`N/Shared/Session/YlPlatformServices.swift`、`tool/apple_hdr/lease_tests.swift`，以及presentation测试与镜像。

**Interfaces:** Task 1的frame与snapshot输入；新增可选能力，现有普通输出默认nil：

```swift
protocol YlTimedVideoEndpoint: AnyObject {
  func update(_ snapshot: YlPresentationClockSnapshot, generation: UInt64)
  func enqueue(_ frame: YlFrameEnvelope) -> Bool
  func retire(removingImage: Bool, completion: @escaping () -> Void)
}
protocol YlTimedVideoOutput: AnyObject {
  func makeTimedVideoEndpoint() -> (any YlTimedVideoEndpoint)?
}
```

- [ ] 写失败测试：`testTimedLeaseRejectsBeforeCommitAndAfterReplacement`、`testLateTimedFlushCannotClearNewLease`、`testTimedLeaseCloseDoesNotWaitUnderSessionLock`。使用测试`RecordingTimedEndpoint: YlTimedVideoEndpoint`保存frame.ptsUs和retire completion；其三个方法只记录参数，不模拟显示。通过真正owner/lease执行以下序列：

```text
makeLease A → A.makeTimedVideoEndpoint：没有可提交权限
commit A → endpoint A.enqueue(frame A)：接受一次
makeLease B / commit B → endpoint A.enqueue(old frame)：false
旧retire completion触发 → B仍保持当前权限，不收到A的错误
owner.dispose两次 → B权限撤销；任何晚到enqueue均false
```

- [ ] 运行RED，然后实现owner/lease的线程安全权限令牌：检查身份与权限必须跟提交操作有明确串行顺序。owner先撤销权限，再发清理；不持锁执行系统enqueue/flush或用户callback。旧endpoint异步退役完成前不开放替代endpoint，不创建无界退役列表。
- [ ] 普通publish、待commit的一帧缓存与AVPlayer binding保持原行为；只有显式请求定时endpoint的lease进入新路径。以`lease.makeTimedVideoEndpoint()`进入，禁止协调器直接取底层真实输出。
- [ ] GREEN运行lease工具与presentation测试、镜像检查；提交`feat: fence timed video output by session lease`。

### Task 3: macOS系统renderer与worker生命周期

**Files:** 新建`N/macOS/YlMacosTimedVideoEndpoint.swift`、`N/Shared/Clock/YlTimedVideoPump.swift`；修改`N/macOS/YlMacosTextureOutput.swift`、`N/Shared/VideoToolbox/YlSampleBufferVideoRenderer.swift`、`N/Shared/Clock/YlPresentationCoordinator.swift`、`N/Shared/Session/YlManagedPlaybackSession.swift`及presentation测试与镜像。

**Interfaces:** endpoint采用Task 2协议；pump独占Task 1窗口，使用以下初始化依赖：

```swift
init(scheduler: any YlPresentationScheduling,
     endpoint: any YlTimedVideoEndpoint,
     clockSnapshot: @escaping () -> YlPresentationClockSnapshot,
     generation: UInt64)
func synchronize()
func stop(completion: @escaping () -> Void)
var hasPendingPresentation: Bool { get }
```

- [ ] 先写`testTimedPumpStopsAdmissionOnPause`、`testTimedPumpCloseFencesReadyCallback`、`testTimedEOFKeepsFutureVideoPending`。给pump注入Task 2记录endpoint及受锁保护的clockSnapshot，在测试屏障上冻结worker；pause/seek/close后释放屏障，验证旧enqueue不能穿越。另测音频先结束、视频先结束、renderer一直不ready与重复close。
- [ ] RED后实现macOS14可用的endpoint：main附着layer并设置CMTimebase，worker独占sampleBufferRenderer。定时CMSampleBuffer的PTS=frame.ptsUs，duration=frame.durationUs（无效duration保持invalid），不设置DisplayImmediately；reservation关联到样本。共用样本格式/元数据构造，旧立即显示构造默认不变。

```swift
let pts = CMTime(value: frame.ptsUs, timescale: 1_000_000)
let duration = frame.durationUs > 0
  ? CMTime(value: frame.durationUs, timescale: 1_000_000) : .invalid
let timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
// 使用该timing构造样本，沿用既有reservation关联方式。
```

- [ ] worker每10ms合并唤醒并读一致快照，按50ms/3帧双限制取最早帧；ready=false停供，request/stop成对。时钟暂停时设timebase rate=0；resume重锚；seek关闭epoch并flush；新epoch等待旧清理完成。不要把整个`presentationDidTick`搬到worker。
- [ ] 在session新增内部`timedVideoCandidateEnabled: Bool = false`注入；以平台/版本、prepared本地有限、非bounded、原生endpoint可用判断准入；不合格保持旧路径。候选选帧由worker负责，main不同时消费同一调度器。EOF增加`hasPendingPresentation`条件，不能在最后enqueue时早报；firstFrame与错误只向当前main会话投递一次。
- [ ] GREEN覆盖pause/resume/rate 0.25/1/2/4、seek、EOF replay、detach/reattach、close与错误身份。固定已接受请求的控制序列，不对main尚未收到的UI命令作即时生效承诺。提交`feat: add opt-in macOS timed native presentation`。

### Task 4: 真实原生显示层失败与恢复验证

**Files:** 修改macOS presentation/audio测试及镜像；新建`tool/playback_benchmark/timed-video-protocol.md`和`tool/playback_benchmark/collect_timed_video.py`；后者的单元测试放`tool/playback_benchmark/test_collect_timed_video.py`。

**Interfaces:** 同一真实source→managed session→owner→lease→附着原生endpoint；观察记录分列`submitted`、`applicationDrops`、`systemMetrics`、`workerMaxGapSeconds`、`candidateActuallyUsed`。`systemMetrics`缺失为null，不默认0。

- [ ] 写`testActualTimedSurfaceSurvivesMainThreadStall`。以现有实际AVC/AAC素材和真实macOS输出创建测试窗口，等待稳定播放；通过main上的250ms阻塞与worker时间戳屏障证明发生了干预。先旧路径RED，再候选GREEN。两者共享媒体与测量区间，使用同一测试实现的两种注入值。
- [ ] collector先写RED，要求以下坏记录均拒绝：

```python
invalid_records = [
    {'candidateActuallyUsed': False, 'systemMetrics': {'dropped': 0}},
    {'candidateActuallyUsed': True, 'systemMetrics': None},
    {'candidateActuallyUsed': True, 'systemMetrics': {'total': 0, 'dropped': 0}},
]
# 每项必须产生明确的门禁失败，不能由submitted>0转为通过。
```

- [ ] 接入macOS14.4+公开性能指标，保存原始total/dropped/corrupted/accumulated delay及测量起止差；检查非零总帧数、单调计数与真实candidate启用。系统返回nil时明确“不可验收”，不能重复等待直到碰巧有数据。对暂停末帧使用`copyDisplayedPixelBuffer`验证可辨识像素，播放中不能调用它推断连续性。
- [ ] 执行确定性main阻塞的前后对照、暂停末帧与seek新代检查；关闭后验证ledger回零且没有晚到画面/事件。同步记录worker空档，若主线程独立但worker也饿死，记录失败并定位，不扩容掩盖。提交`test: verify timed native output under main-thread stalls`。

### Task 5: 真实激活、集中回归与准入结论

**Files:** 新建`tool/playback_benchmark/run_timed_video_activation.py`及`tool/playback_benchmark/test_run_timed_video_activation.py`；更新`docs/superpowers/reports/2026-10-10-display-activation-root-cause.md`、本计划和新的最终验收报告/portable archive。

**Interfaces:** 复用Task 4记录/collector；将已有归档内的NSWorkspace唯一PID/bundle激活helper纳入runner，保持已有同进程复用与超时清理检查，不操作其他应用。

- [ ] runner先测试失败：缺少实际激活通知、返回不同PID、源码/二进制身份变化、无最终disposed记录、native非零退出，都必须保存原始输出并判失败。测试的subprocess替身仅用于这些进程边界；真实输出验收不能用替身。
- [ ] Debug旧/候选、Profile旧/候选四组串行30s真实激活，固定10s请求、同一素材、无Instruments。分析按request uptime分开前后丢帧：

```python
before = sum(event['count'] for event in events if event['uptime'] < requested)
after = sum(event['count'] for event in events if event['uptime'] >= requested)
assert before + after == active_dropped  # history截断则不能作完整分类
```

- [ ] 对worker最大延迟与系统指标分别判定；若候选仅减少main依赖但系统仍丢帧，保持失败结论并定位剩余供给瓶颈。禁止降低现有100ms门限或将cleanup计数抵消活动失败。
- [ ] 在最终身份运行相关完整macOS回归；共享lease/时钟变化在iPhone18 Pro Max跑对应回归；最后仅一次候选20分钟长播。保存源与二进制hash、退出码、跳过条件、owned进程清理、资源释放。新问题引发补测有明确理由；不每项重复全套。
- [ ] 复算portable archive并检查报告全部数字与链接。候选保持默认关闭，单列本机显示连续性、A5资源边界与R4物理设备限制。完成一次最终代码审查；提交`test: record timed presentation activation acceptance`。不push、不合并、不把整个P08自动标完成。

## 计划自检

Task 1提供Task 3需要的clock/window/scheduler；Task 2提供Task 3的endpoint与身份隔离；Task 4验证Task 3真实显示结果；Task 5沿用Task 4指标而非旧计数输出。五项Review Focus各有对应失败用例。用户已审阅计划；沿用当前任务内执行方式，连续执行，不在每一Task结束时询问是否继续。
