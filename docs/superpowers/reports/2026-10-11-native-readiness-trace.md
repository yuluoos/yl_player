# 原生 ready 等待：系统跟踪与采集扰动

状态：继续定位，未完成严格长播准入。基线`fee2518`；本轮没有修改播放器生产代码，也没有新增20分钟验收。候选默认关闭，productionAdmission=false。采集脚本、分析结果及原始文件SHA收据见`tool/playback_benchmark/macos-native-readiness-trace-observations.json`。

## 诊断目的与设置

上轮无Instruments的1200.501秒诊断有2帧系统丢弃，伴随119.084ms的ready=NO等待；时钟新鲜、worker响应快、native锚定不变。本轮目标是取得显示／线程事件，不以Instruments运行替代正式验收。

Xcode27.1可用。先用自有sleep进程做5秒System Trace＋Core Animation Server＋Display预检。录制与最终导出成功；首次导出发生在保存结束之前，返回Document Missing Template Error，属于采集时序错误，不是工具不可用。最终约212MB，中间数据曾约1.8GB。随后构建Profile成功，两轮播放器诊断使用相同采集范围源码及二进制SHA。运行协议明确instruments=true、diagnosticOnly=true；每轮只附加到其首条playing记录确认的自有PID。

## 结果

| 运行 | 活动时长 | 系统增量／丢弃／损坏 | 活动应用丢帧／时钟过期 | 首次释放归零 | 结论 |
| --- | --- | --- | --- | --- | --- |
| activation：30秒环形保留 | 30.182s | 727／1／0 | 0／1 | 358.609ms | 失败，且未覆盖故障早期线程事件 |
| bounded：15秒固定录制、不裁剪 | 30.196s | 726／2／0 | 0／0 | 211.249ms | 失败，捕获一次共同线程停顿 |

两轮原生测试均1项失败、0跳过，xcodebuild退出65，自有播放器PID退出，runner无异常，采集范围内源码／产物未变；均有暂停后另加1次应用超时，未混入活动期计数。各自dispose调用344.901ms／198.061ms，账本归零。没有改写任何失败为通过。跟踪进程最终均退出0。

环形轮活动约7.05秒系统计数+1，最大worker间隔97.401ms、音频读79.660ms、年龄101.161ms、stale1。trace目录标记28.989秒、Windowed(30 seconds)，但导出的目标context-switch范围仅22.926715..28.951675秒，display-surface-queue范围22.933819..28.982042秒；故障相关firstRejected在trace相对2.674663秒，完全不被覆盖。应用级display-compositor-interval为空。不能把模板名称、成功退出或文件存在当作故障覆盖证据。约398MB最终trace保留在本机。

固定录制轮的线程状态覆盖0..15.947524秒，故障区间在范围内；最终trace约672MB，中间数据一度约6.1GB。这种设置不适合直接无界延长到20分钟。原始跟踪包含系统进程目录，留本机，不提交全文。

## 已对齐的共同停顿

公开time-info给出mach absolute epoch2419369068120、timebase125/3，对应uptime100807.044505秒。worker慢tick从trace0.878523667到0.923499917秒，scheduler阶段43.717667ms。

worker线程0x302514在0.879182958..0.922062583处于Blocked，42.879625ms，几乎覆盖整个scheduler耗时。前一切换栈为`pthread_cond_broadcast → YlFrameScheduler.nextFrame → YlTimedVideoPump.tick`，后一栈为`pthread_mutex_unlock`相关慢路径；这分别涉及唤醒与解锁，不能把整段写成等待FrameScheduler互斥锁。

同时主线程、VT回调、Core Animation imagequeue、音频IO实时线程、音频采样相关线程等7条线程进入Blocked，共同重叠35.472208ms，结束时间集中在0.922060708..0.922077750，仅相差17.042µs。它们的等待栈涉及不同机制；这与进程级暂停或共同调度停顿一致，不支持单一帧队列锁独占解释。madeRunnableBy、preemptedBy、yieldedTo等字段均为空，没有直接暂停发起者证据，不能认定发生了task_suspend，也不能认定Instruments是唯一原因。

恢复后约0.9225秒出现`AGX::agxaSignpostInitialize`、`_registerForSignpostEnablement`及IOGPUMemoryInfo资源信息输出，为跟踪启用扰动提供调查线索。该相关性不等于已证明因果。

活动约第6秒的相邻观测区间系统计数增加2；没有ready反压记录、lateEnqueues=0、累计最小入队提前量4.084ms、音频stale=0。native锚定1→2，记录一次46.626333ms向前校正（uptime100807.983132）。计数与校正在同区间，但缺逐帧身份映射，不能断言两帧分别由该校正造成。它与上轮锚定不变的119ms ready等待不是相同已证实机制。

## 裁定与后续定位

本轮不修改scheduler、音频时钟策略或ready契约，不扩大50ms／3帧窗口，不放宽零丢帧门禁。已确认应先区分采集启用扰动和真实长播ready等待，不能因出现新的43ms耗时就再加入一个生产锁补丁。

后续优先让跟踪完成启用后再开始播放，或逐项减少附加instrument，保持相同产物、媒体及播放后10秒外部激活；需要明确的开始通知或测试门闩及有界超时，不能凭固定sleep认定采集稳定。记录应在仍覆盖故障的时间范围内停止，导出后验证覆盖；正式长播继续单独关闭Instruments。原119ms区间内部原因、严格长播准入、R4物理输出和A5系统资源总上界均未完成。

独立只读复审：Critical无、Important无；1处Minor要求把“进程级暂停”改为“与进程级暂停或共同调度停顿一致”，已校正。审查不认可关闭当前任务。
