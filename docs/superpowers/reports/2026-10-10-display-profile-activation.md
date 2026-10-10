# Profile/AOT首次激活对照

基线`3f41cb0`，生产源码与测试源码均未修改。独立Profile arm64构建成功后运行同一30s解码连续性测试，以NSWorkspace激活唯一已运行Runner；没有Instruments。**Profile同样失败，不能将问题限定为Debug JIT。** 该结论不意味着Profile必然比Debug更慢，也不单独量化JIT贡献：Flutter运行时、Swift优化和运行时间均不同。

## 实际结果

| 项目 | 结果 |
| --- | --- |
| XCTest | 0通过、1失败、0跳过，退出65 |
| 活动丢帧 | 12：catchUp 5、enqueueTimeout 1、lateAfterCapacity 2、lateArrival 4 |
| 相对激活请求 | 请求前1帧；请求后11帧；不能把12帧全部归于激活 |
| 最大CADisplayLink入口间隔 | 455.030ms；22220.957356→22221.412387 |
| 最大refresh / body执行时间 | 1.772 / 2.163ms |
| 最大视频落后 | 224.750ms，超过原100ms门限 |
| utility探针最大调度空档 | 206.806ms |
| 测量结束到关闭额外丢弃 | 8次enqueueTimeout，独立于活动12帧 |
| 关闭后 | ledger=0，pending=false，已知构建/Runner/Xcode/caffeinate进程全部退出 |

外部工具请求uptime22220.903317，返回22221.179476、active=true且sameOwnedPID=true。窗口成为key记录为22221.078929，应用成为active为22221.108679。最长回调空档与激活重叠；第一帧活动catchUp发生于22220.558467，早于请求。全部后续11帧发生于22221.192477…22221.533804。后台utility探针也延迟，既有证据不能将455ms全数解释为主线程连续执行某一个函数；本次没有调用栈采样。

产物`App.framework/App`包含`_kDartVmSnapshotInstructions`和`_kDartIsolateSnapshotInstructions`，构建配置为Profile，记录保留AOT符号输出。执行前后462份源码/输入与216个宿主包文件哈希一致。216项包含资源与框架，不能表述为216个独立二进制。

首次多架构Profile构建退出65：Flutter将`arm64 x86_64`作为一个架构参数处理，虽然lipo输出已包含两种架构，仍报不匹配。保留失败日志；改用`ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`和独立derivedData目录后构建退出0。未更改Flutter源码或工程部署下限。此构建恢复不是播放器修复。

## 对后续工作的约束

现有测试的`DecodedTexture`是计数输出，**没有附着原生显示层**；因此本次证明的是解码/音频运行时的显示调度失败，不是像素输出测量。下一步必须使用真实原生层，通过有界后台投递和系统显示指标验证，不以提交帧数代替显示帧数。

后台worker必须记录自身饥饿；若进程整体调度延迟超过50ms窗口，不能通过放宽丢帧门限或无限增加缓存宣布成功。确定性main阻塞与真实激活分别验收。物理音画、macOS12/Intel和额外设备仍未验证；生产音频候选准入、A5整体下游边界均不改变。

用户已审阅并同意[定时显示候选设计](../specs/2026-10-10-macos-timed-presentation-design.md)。本轮整理设计和实施计划，尚未写入生产修复。可移植[原始记录与复算脚本](../../../tool/playback_benchmark/macos-display-profile-activation-observations.json)保留构建失败、原生失败、身份、计数和关闭证据；设备标识做确定性脱敏，保存原始与脱敏后字节哈希。
