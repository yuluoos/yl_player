# 长播空档、系统丢帧与退出阻塞：继续定位

历史诊断状态：本报告保存隔离实施前的失败与受控复现，基线为`b357849`，不覆盖原始结论。后续已实施音频锁隔离及时间配对修复，完整20分钟验收仍因系统丢4帧不准入，见[实现与验收报告](2026-10-10-audio-clock-isolation-acceptance.md)。候选仍默认关闭。

## 已定位的退出延迟

给pause、暂停像素读取、session dispose、owner dispose增加逐阶段落盘记录。Debug短播在dispose内耗时10.994s，暂停与像素读取均完成；超过5s后只采样本轮owned PID。主栈位于AVAudioPlayerNode.stop → AVAEDispatchQueueTimer.CancelTimer → libRPAC.interposed_dispatch_semaphore_wait → qosWaiterSignallerInvariantCheck → generateCulledBacktrace/符号解析。不是本轮像素读取阻塞。

同一Debug二进制，仅从此次测试manifest移除Thread Performance Checker的libRPAC/PERFC注入后，dispose为0.181s；Main Thread Checker与XCTest注入保留。该组系统丢2帧，仍判失败，不能把释放改善写成整体通过。随后Profile短测运行时确认RPAC未加载、Main Thread Checker仍加载；dispose为0.202s，活动系统增量725帧/丢0/损坏0。原20分钟超时也注入了RPAC，但没有当时的线程栈；短播对照支持检查器造成显著退出开销，尚不证明原超时的每一步均同因。

Apple明确说明此检查器会插入运行时检查，某些应用能触发可见开销；性能测量应排除其影响（[Apple文档](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early)）。仅改变本轮manifest，不关闭项目日常检查，不压掉测试失败，不放宽性能门限。

## 分段定位与采集器修正

原worker空档在clockSnapshot之后计时。默认关闭的诊断将idle、clock、native update、scheduler、enqueue、整次tick分开，保留最多32条超过40ms的tick。120ms时钟读取测试先失败，再确认能够独立归因；没有改变播放队列、时钟算法或50ms/3帧限制。

移除检查器的Debug失败中，clock读取最大59ms、idle最大79ms；丢帧附近存在+62ms/-46ms timebase校正。这是相关证据，不足以区分同步读取阻塞与线程在API调用期间被抢占，也不证明校正是全部丢帧原因。

runner原先每200ms读取并解析全部历史，只为重复获取首条PID；长播诊断日志增长会引入不必要的持续解析负载。修正为第一次取得owned PID后不再读取历史，最终验收仍完整解析一次；异常清理/落盘测试先RED再GREEN。本修改降低采集负载，但不能单凭源代码证明历史146.8ms空档全部由此引起。

## 被中止长播的诊断协议

同一Profile二进制，20分钟，外部精确PID激活仍在10s；关闭Thread Performance Checker并从动态加载列表验证，保留Main Thread Checker。按秒采集系统指标、分段耗时和native校正历史，记录Space/显示器/睡眠事件。额外只读所属播放器和采集器的proc_pid_rusage计数、footprint及全机负载。所有失败保留；这些附加观察使其属于诊断运行，不冒充无诊断正式长播。若退出阶段再次超过5s才采样线程栈。

本机曾出现约6.2GB内存压缩，15GB已用；不能仅凭全机概况把空档归因于换页，需要与所属进程计数及具体时段核对。进程footprint与应用ledger均不能证明A5系统整体资源上界。R4物理输出及未具备设备仍开放。

## 暂停后的实际状态与恢复

用户在诊断长播期间明确要求暂停。采集器收到SIGINT并保留`KeyboardInterrupt()`与退出码-15；最后一条活动记录为1119.840323s，不足20分钟，没有activeEnd、暂停像素或disposed记录，不能作为完整长播验收。原始run.json的即时ownedProcessExited=false保留；独立后续检查确认本轮五个进程均退出，记录在post-pause-cleanup.json，不覆盖原始失败。

截至最后一条活动记录：系统增量26874帧、丢66、损坏0；应用丢3、worker拒绝0；最大worker空档330.011ms。分段最大值：clock320.748ms、idle213.227ms、native update270.504ms、scheduler62.367ms、enqueue197.980ms。这些是不同tick的墙钟耗时上限，不能相加、不能直接当CPU耗时。

375.049s处窗口短暂不可见，系统丢帧先增加4、随后增加6；用户确认当时做过窗口／桌面操作。此处供帧计数继续增加，late enqueue计数未变，支持显示环境转换与这10帧丢弃相关；尚未建立受控因果，也不解释旧153/158帧异常的全部原因。后续全机1分钟负载最高638.56，已采样的iPhone18 Pro模拟器系统组件占用明显。用户授权临时关闭该Pro；命令执行时设备已Shutdown，不能把负载回落归因于助手关闭操作。Xcode随后消失，运行中止；这些变化均属于测量环境扰动。

恢复后已实际执行xcodebuild版本、swiftc定位、macOS SDK定位与firstLaunchStatus检查，均正常：Xcode27.1（27A9275），MacOSX27.0.sdk。没有变更xcode-select或重装工具。

## 已证实的音频引擎锁依赖

高负载期间的3秒sample捕获以下实际链路：

```text
YlTimedVideoPump.tick / synchronize
  → YlPresentationCoordinator的clockSnapshot
  → session音频时钟闭包
  → YlSystemAudioOutput.renderedAudioTime
  → AVAudioNode.lastRenderTime
  → AVAudioNodeImplBase::GetAttachAndEngineLock
  → sleep_for / nanosleep / __semwait_signal
```

timer路径有103个该锁等待样本，synchronize路径有52个。主线程displayLinkTick及demux音频enqueue/retry也出现同类等待。源码印证：主线程、独立视频worker、音频入队均同步咨询同一输出；worker在得到clockSnapshot之前不更新timebase、不取帧、不enqueue。因此，“worker独立于main”并不意味着其不依赖音频系统锁。它确实曾等待系统锁，不能把全部clock耗时解释为单纯CPU抢占。

同一sample中AVAudioIOUnit队列还在BufferCommand销毁→输出延迟查询→CoreAudio属性调用，但sample没有锁拥有者信息，不能据此认定该队列就是GetAttachAndEngineLock等待的持有者。不能声称已定位到Apple内部具体锁持有函数或全部系统丢帧的唯一根因。

## 受控复现与时间配对风险

在真实YlMediaClock、YlTimedVideoPump和调度器上运行两个临时诊断方法，完整源码和patch进入证据归档；测试后恢复测试文件原内容，不把“复现了错误”作为永久的通过标准。

1. `testDiagnosticAudioReadBlocksTimedSupply`：只在外部音频读数边界注入信号量阻塞。帧40ms已在队列、输出可用；阻塞120ms期间没有enqueue且帧仍待处理，释放后才投递。clock诊断超过100ms。证明该同步调用会直接停止视频供给；未模拟Apple锁持有者。
2. `testDiagnosticLateAudioSampleUsesEarlierHostAnchor`：用可控音频读数模拟1.000s请求、1.120s取得读数。真实媒体时钟返回position=1.120s、host=1.000s；真实CoreMedia timebase在host=1.120s转换得到media=1.240s，重复计入120ms。这证明调用前host时间与返回时媒体位置组合可能造成前跳，不证明真实lastRenderTime每次都对应返回时刻。原生读数自身年龄、renderer归一化与并发更新仍需一并处理。

本轮presentation套件29/29、0跳过：27项现有测试加2项临时诊断。属于诊断结果，不是“显示卡顿修复通过”。此前分段诊断GREEN结果已补导出为27/27。

## 恢复后的短播对照

保持原Profile二进制、显式去除本轮Thread Performance Checker、保留Main Thread Checker和诊断参数，执行一次30秒真实外部激活观察。native与collector均成功，source/binary未变、owned PID退出确认；活动系统增量725/丢0/损坏0，应用丢0，worker空档19.471ms，clock最大12.017ms，无超过40ms慢tick。dispose151.253ms，暂停像素和后续资源归零检查通过。

这次短测发生在环境恢复后；没有构造与先前模拟器超载相同的受控压力，不能作为隔离单变量的性能改善证据，也不消除被用户中止的失败长播。本轮未再次跑20分钟长播。

## 修复边界与后续验证

本轮完成Xcode恢复检查及阻塞传播定位；尚未实现音频时钟隔离修复。下一步应先确定真实音频位置对应的host采样时刻，再把可能阻塞的AVAudioEngine读数从视频供帧关键路径隔离。若使用独立采样者，必须同时定义快照有效期、音频停顿/结束/暂停、rate、seek和epoch失效规则；过期不能无期限外推或伪装成无音频host回退。仅将host时间改成调用结束时刻，或只减少主线程查询次数，都不足以证明修复。

继续保留50ms/3帧限制、100ms验收门限、默认关闭和productionAdmission=false。修复后需先用可控慢读与生命周期测试证明行为，再进行真实层与实际激活对照；不得用一次短测成功覆盖旧失败。A5整体资源上界、R4物理输出及未具备设备仍开放。

## 可复核证据

可移植归档：[macos-timed-clock-investigation.json](../../../tool/playback_benchmark/macos-timed-clock-investigation.json)。每条记录保存原始与脱敏SHA-256、gzip+base64内容；包含阻塞栈、运行协议、身份、逐秒记录、进程资源、暂停/清理回执、受控诊断源码及原生结果。旧归档不覆盖。中止长播的collector失败按原始缺失边界保留，统计摘要另列，绝不补造activeEnd/disposed。
