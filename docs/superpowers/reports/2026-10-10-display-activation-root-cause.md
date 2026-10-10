# 首次窗口激活引发的显示调度卡顿

基线 `90a14ed`。本轮把“回调进入前的延迟”推进到可触发的具体路径：**macOS Flutter Debug 测试宿主首次进入前台时，AppKit 激活、Flutter 生命周期/JIT 和文本输入系统初始化占用主线程；同一主线程上的 CADisplayLink 无法按时交付，视频队列随后 catch-up 丢帧。**

原始失败的同期系统日志与受控复现相符；去掉 Instruments 后仍复现。因此“首次激活期间主线程工作阻塞显示供给”有受控实验支持，历史失败归因到该路径有很强证据。但历史55秒事件没有完整同期调用栈，不能还原其中每个函数的确切耗时，不能把新采样栈冒充历史栈。

## 原始失败的同期证据

原 Runner PID 60187；既有线程样本确认主线程为684372。新读取只限定该进程、该时间段，没有读取剪贴板内容。系统日志的 `machTimestamp` 按本机 `mach_timebase_info` 的125/3纳秒比例换算，直接与播放器 uptime 对齐，不依赖墙钟估计：

| 原始窗口 | 同期主线程操作 | 后果 |
| --- | --- | --- |
| 14447.443976 → 14447.735225，291.249ms | +193.167ms读取CFPreferences；+282.158ms请求剪贴板的UTF-8类型 | 队列容量3无法被消费，先出现251.023ms入队超时，随后catch-up丢2帧 |
| 14447.735237 → 14447.945685，210.449ms | +7.884ms首次选择IMKClient_Modern；随后创建IMKInputSession与多个输入法XPC连接 | 再丢2帧，并发生等待容量后的过期帧 |

原始首次失败累计9帧、最大落后199.375ms仍保留。`NSPersistentUIManager flushAllChanges`日志出现在00:05:42.343，晚于上述00:05:38.910…39.412区间，不能将本轮另一种状态保存卡顿误认为原始触发点。

## 受控实验与结果

全部单独运行，不并行原生测试。生产代码未改；每次保留执行前后462份源码/输入与5份二进制身份。最终提交仅保留显式`YL_DECODED_ACTIVATION_DIAGNOSTICS=1`启用的被动激活通知记录（16条上限、defer移除观察者），不在测试内请求激活；曾尝试的无效内部激活分支只保留在历史实验源码中。普通验收不启动观察者。外部激活工具检查bundle路径和唯一已有PID，通过NSWorkspace复用该进程，不启动第二实例。

| 实验 | 结果 | 可支持的结论 |
| --- | --- | --- |
| 原版本、等待线程采样及回调探针 | 1活动catch-up；52.754ms回调空档；7个主线程栈落在AppKit持久化保存路径 | 另一个真实阻塞源：状态保存中的WindowServer/LaunchServices同步查询。与历史原始激活事件分开 |
| 原版本、关闭回调探针及等待线程采样，保留CPU采样 | 210.202s观察、0活动drop；仍捕获状态保存栈，样本跨度36.002ms | 未丢帧不能证明不曾执行保存；此对照同时改变两项诊断设置，不单独归因于某一项 |
| 应用内部NSApp.activate请求 | 原生1/1通过，但每行applicationActive=false | 没有实现目标激活，不用于否定激活假设 |
| 外部激活已有Runner，带CPU采样 | 激活窗口内5帧丢弃；另有较晚1帧，共6活动drop；原生失败 | 最大回调间隔157.865ms；栈包含AppKit激活、Dart JIT、TSM/IMK输入法初始化/XPC等待；refresh/body最大0.896/2.866ms |
| **同一版本、同一外部激活步骤，移除CPU采样** | **4活动drop，原生失败；最大回调间隔147.723ms** | **排除“卡顿仅由Instruments采样造成”；剪贴板→IMK初始化的日志顺序也与原始一致** |

无采样复现的refresh/body最大1.180/1.158ms，最大视频落后82.375ms。外部激活确有NSWindowDidBecomeKey与NSApplicationDidBecomeActive通知，而非仅凭API返回判断成功。之后记录到失活通知，发生在所有4帧丢弃之后，不用于解释先前失败。两次外部激活实验释放后ledger=0、pending=false；测量结束到清理观察分别新增3/1次enqueueTimeout，单独保存，不冲销活动阶段失败。

采样实验中“Running”标签不证明线程持续占CPU，尤其记录等待线程时；这里使用具体栈与回调窗口重叠，不把统计样本权重当作函数精确耗时。trace起点导出精度为1ms，采集器墙钟/单调钟差值漂移小于2µs，结论不依赖窗口边缘单个样本。

第一次采样的测试中断清理超时导致xcresult未完成，无法导出原生计数；这项限制连同退出-15和导出失败原样保存。trace本身成功导出，原始JSONL和身份校验仍可核查。其余主动中断或失败均不计正式门禁通过。

## 对修复的含义

`YlDisplayTimer` 在main/common运行；`YlPresentationCoordinator.displayLinkTick`在该回调中消费队列。此次复现中回调内refresh/body均不足3ms，缓存NSScreen或调整catch-up条件不能解决回调之前的百毫秒阻塞。增大队列或忽略drop也不会补回已经错过的物理显示时间。

现有原生输出同样经`YlVideoSurfaceMailbox`转回main；`YlSampleBufferVideoRenderer`在main请求数据，样本时间戳为zero且立即显示。因此不能只把定时器搬到后台就声称消除了卡顿。要处理前台激活时仍需持续显示的产品要求，需要有界、按PTS提前排队的原生显示路径，并独立验证暂停/seek/切轨/代际清理、音频时钟、资源所有权及真实显示结果。Debug宿主的Dart JIT影响还须与Profile/Release结果分开。

本轮**完成了触发路径定位与可复现失败基线**，没有宣称修复了这类前台激活卡顿，也没有将历史失败撤销。先前稳态本机短/长播通过记录保持有效；激活扰动的恢复能力仍是明确的未完成项。默认开关、生产准入和整体下游资源上界继续false；A5、R4及整个P08不改为完成。iOS源码未变，本轮不新增iOS运行声明，后续仍优先iPhone18 Pro Max。

[原始记录、日志、完整导出栈、身份与复现脚本](../../../tool/playback_benchmark/macos-display-activation-observations.json)。AppKit公开状态编码接口要求调用super，不能通过空实现规避系统工作（[Apple文档](https://developer.apple.com/documentation/AppKit/NSResponder/encodeRestorableState%28with%3A%29?language=objc)）。

## 最终提交版本验证

最终源码删除了无效内部激活分支，仅保留被动观察。相同最终身份串行检查：外部激活、无Instruments再次复现4活动drop（原生0/1）；默认关闭独立短播原生1/1通过，0活动drop，观察者历史为空，未启动时序探针或外部采样。两组均保持源码/二进制身份，关闭后ledger=0、pending=false。没有重跑或宣称全套675项/20分钟门禁是此次测试源码的新结果；先前通过仍按原身份引用。生产源码未改，镜像及发现计数iOS680/macOS676保持。
