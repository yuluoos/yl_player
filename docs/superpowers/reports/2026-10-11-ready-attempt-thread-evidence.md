# ready 逐次检查与线程证据

沿用用户连续定位119ms等待、捕获完整线程证据并据此修复的授权。候选默认关闭，生产准入关闭；不绕过ready，不放宽50ms／3帧、100ms时钟新鲜度、零系统丢帧和3秒释放条件。

## 本轮要解决的证据缺口

历史119.084ms事件只有13次拒绝的计数及首拒绝／回调／enqueue边界，没有每次检查的时间和线程。仅凭这个计数，不能证明各次检查按10ms均匀发生，也不能区分显示队列等待、同步getter等待与持续观察到ready=false。

在既有 `collectDiagnostics` 开关下新增有界标量记录：前32次及最后一次检查的调用请求、串行队列入口、getter起止、布尔结果和线程ID；总次数及省略次数显式记录。首拒绝时间使用首次getter返回时间，避免记录器自身开销改变此边界。注册与回调分别记录首次／末次及次数；回调进一步区分入口、stop返回、ready读取返回。记录不持有帧或缓冲，完成事件仍最多16条。诊断关闭时不记录这些时钟或线程ID，不改变原有ready读取、请求／停止、入队顺序。

注册／回调并非完整逐次配对历史：出现多次时不得把末次注册与末次回调直接相减后断言单次延迟。回调时间也不是内部ready翻转的精确时刻。Apple文档说明ready随内部队列消费异步变化，且不是KVO属性；框架择机调度回调。不能用KVO推断翻转，也不能把API弃用标记解释为本次故障原因。[AVSampleBufferVideoRenderer](https://developer.apple.com/documentation/avfoundation/avsamplebuffervideorenderer)、[回调合同](https://developer.apple.com/documentation/avfoundation/avqueuedsamplebufferrendering/requestmediadatawhenready(on:using:))；并已核对本机Xcode27.1 SDK同名头文件。

## 探针验证

- 纯记录器RED：缺少队列请求时间的断言失败；GREEN验证不同线程、队列等待／getter等待的独立边界、上万次检查仍有界、首末观察与重复回调计数。
- 真实原生RED：未接入记录器的端点在暂停满队列下实际返回false，随后因 `readyChecks` 缺失而断言失败。前两次构建分别因Flutter多架构参数解析和Profile缺少ENABLE_TESTABILITY中断，单独保留，不计为行为RED。
- 真实原生GREEN：接入后显示调度测试类40/40通过。该用例以暂停满队列和flush主动构造反压／恢复，只验证记录器，不能作为历史119ms复现。
- 只读复审没有Critical／Important问题；指出注册／回调只保留首次／末次和次数，上述解释边界已记录。

以下记录完整原生回归、稳定启动后的跟踪、实际样本覆盖与本轮最终验证。证据目录 `/private/tmp/yl-ready-attempts`。上一轮无跟踪1200.171秒通过保留，但不能代替本轮改动后的验证，更不能据此宣称119ms根因已修复。

## 回归中发现的既有等待问题

完整原生回归为721/725通过，4项失败集中在AppleHost会话替换／generation／delta及DASH替换恢复的异步回调。使用未加入本轮探针的冻结产物单独重复这些测试，四项同样失败；对应测试源码与冻结版本哈希一致。原夹具仅执行12次Task.yield，不能保证MainActor上串行发送的回调已经交付。

修正仅限测试：等待目标session，或精确delta版本；DASH在各操作后固定捕获session及revision下界，等到对应状态交付后继续原有tracks、身份、URL和停止断言。未修改生产回调，不延长通用settle，不以最终期望tracks作为等待条件。旧失败结果保留在native-regression.xcresult及baseline-four.xcresult；后续相关测试类复验结果见下文。只读复审未发现弱化断言或阻断问题。

Python采集与辅助测试239项通过（15.441秒），包括新增的Swift逐次ready记录器测试。

修正后的首次相关类复验107/108：DASH等待超时暴露了测试等待协议的另一处错误——delta也推进同一revision，完整状态未必发布该版本。改为目标session完整状态已交付，且同session的state／delta最大版本覆盖捕获版本；串行FIFO保证此前状态已交付，tracks仍按原精确值断言。最终三个相关类108/108通过（native-delivery-green.xcresult）。因此验证记录为完整回归721/725及修正后相关108/108，不声称同一次725项全绿。

已冻结应用YLReadyProbe.app，并启动60ms诊断阈值的20分钟System Trace；该阈值只决定保存证据，不更改准入条件。

## 采集启动校验

`long-ready`在播放前因更改副本bundle ID后未重新签名而退出，crash明确为OSStatus -67030；未产生有效采集。`long-ready-signed`恢复主应用签名后进入XCTest，但尚未测量就失败；与旧成功副本对照发现新副本保留App Sandbox，而旧基准副本无entitlements。仅对临时副本恢复既有无沙盒测试配置（源应用／生产权限未改），主应用codesign严格验证通过；嵌套RunnerTests的deep验证警告也存在于原构建产物，不能声称deep验证通过。两次失败目录和结果保留。

`long-ready-testhost`成功通过真实录制通知与原生稳定门控：连续稳定2.005秒，最大间隔12.162ms，0次重置，随后才开始播放。唯一玩家PID15947、录制服务15945（父xcodebuild15943），原始数据保留流程绑定该身份。

## 首次有效长播与新增丢帧触发

`long-ready-testhost`完成1200.456秒播放：系统区间28811帧／丢弃1／损坏0，播放阶段应用丢帧0、时钟过期0；最大worker间隔19.242ms，最大音频读24.992ms、样本年龄31.862ms。全程没有ready拒绝、晚enqueue或观察到的窗口不可见。退出后两次ledger均为0，源码／二进制身份未变。严格收集器因系统丢帧和原生失败返回false，不能作为通过。

系统计数首次增加位于uptime119209.694717至119210.697836之间，已保存前后完整行；CoreMedia同PID日志证实显示队列dropped1，而解码丢弃和输出late统计0。没有同刻线程样本，不能进一步指认原因，也不能把它解释为历史119ms：本轮没有任何ready=false。ready-only触发没有捕获该较早事件，最终滚动窗口仅覆盖尾段。

为补上这个独立证据缺口，增加可选`--capture-system-drops`，保留计数增加前后行；缺失／非有限／负值忽略，计数回退重建比较基线。完整ready事件仍优先，且保留关联drop行。系统丢帧触发后每次轮询检查最新快照；若观察到pending或缺失诊断，延后停录，恢复后重新保留至少250ms尾段。它只保证最新已观察状态，不等同于原子读取原生当前状态。

两阶段RED／GREEN覆盖丢帧无ready、计数边界、触发前pending及触发后尾段pending／恢复，16项专门测试通过；复审指出的尾段提前停止问题已修复。原生播放器行为及准入条件未改变。

## 已捕获的独立系统丢帧窗口

`ready-or-drop`约第14.065秒自动触发系统丢帧，保存完成后主动结束诊断播放；该运行缺少完整结束边界，不能作为验收。原始ktrace恢复出18.984939秒、1,364,626条切换样本。估计的计数观察区间落在播放器17880与WindowServer423的实际样本时间范围内（分别8,488条／15线程、3,362条／13线程）。16组唯一的TID／状态／栈地址样本对齐符号化记录和原始记录，偏移1.053120375秒；host-wall对齐来自同PID日志，内部离散1.441ms，不代表绝对误差。

计数观察区间uptime119861.682126至119862.684983；row时间并非指标读取的原子时间或精确丢帧时间，因此不能把它称为单帧精确区间。该时段无ready拒绝、late enqueue、时钟过期或锚点变化；最小提交提前量35.837ms。CoreMedia显示队列1帧丢弃，解码丢弃0、输出late0。WindowServer主线程在区间内累计运行207.134ms，最长Blocked13.837ms，不能据此支持整个WindowServer停顿119ms。

播放器TID3774782／3773829的16.436ms／15.393ms Blocked入口与非空栈时间精确一致，栈为`__psynch_mutexwait → recursive_mutex::lock → AVAudioEngine.outputNode → YlIsolatedAudioClock.sample`；这是已隔离的音频读路径。另一7.991ms等待位于音频enqueue的clock读取，4.083ms等待附近可见音频缓冲释放，但后者栈早101.541µs，仅为邻近样本。音频读等待与系统丢帧同处约1秒统计区间，不足以证明因果；上述锁等待栈来自音频路径，未取得显示路径直接等待该锁的证据。

本轮捕获完成的是独立系统丢帧的线程窗口，并非119ms ready事件。后者仍未复现，未作推测性生产行为修改。新增修改为有界诊断及采集可靠性、测试回调等待修正；候选／生产准入继续关闭。

## 最终无跟踪验证与结论

`final-untraced`同一冻结副本连续观察1200.132790秒：28803帧，系统丢弃0／损坏0，播放阶段应用丢帧0、时钟过期0；最大worker间隔14.933ms、音频读17.772ms、样本年龄25.791ms。dispose493.707ms，两次资源账本均为0，原生测试1/1通过，runner退出0，播放器已退出，源码／二进制未变化，严格收集器passed=true。未启用Instruments、逐秒系统／transport诊断；边界计数与生命周期记录保留。该结果不能抹除本轮带跟踪的系统丢帧，也不能证明未复现的119ms等待已修复。

本轮完成有界逐次ready探针、真实原生RED/GREEN、既有异步测试等待修正、丢帧自动采集与尾段保护，以及上述独立系统丢帧的线程窗口分析。验证为完整原生721/725、修正后相关108/108、Python243/243、最终无跟踪1/1；不拼接为单次完整全绿。

**当前任务线仍未全部完成：历史119.084ms ready事件没有复现，尚缺同一事件的内部根因及有依据的修复验证。** 不将16ms音频锁关联、单次稳定长播或独立系统丢帧冒充其闭环。候选保持默认关闭，productionAdmission=false；没有绕过ready或放宽任何准入门槛。

结构化归档见`tool/playback_benchmark/macos-ready-attempt-observations.json`，包含可重算运行记录及压缩后的选定证据；大型ktrace／XML仍保留在`/private/tmp/yl-ready-attempts`，不嵌入Git。
