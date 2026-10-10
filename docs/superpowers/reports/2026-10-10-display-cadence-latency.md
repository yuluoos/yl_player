# 显示调度延迟定位与长播环境修正

基线 `2235024`。范围：继续区分原生显示回调供给、`refreshCadence` 与播放器帧调度耗时，并修正本机连续播放验收条件。原先55秒处9帧丢失及199.375ms落后仍是有效失败，未被后来的未复现覆盖。

## 已定位的边界

测试通过既有 CadenceFactory 包装真实 `YlSystemDisplayCadence`，测量回调入口、refresh结束、帧调度退出；生产只调整该类的模块内可见性，不改变节拍。所有探针默认关闭。32条慢事件、16次主队列响应、256条运行循环活动有界；停止后不再更新。

| 一次性诊断 | 观测 | 结论与限制 |
| --- | --- | --- |
| 回调边界，120.106s | 0活动drop；入口间隔最大43.696ms、refresh最大6.907ms、body最大3.274ms | 对应最长间隔事件的refresh仅48.375µs、body409.708µs，延迟在原生回调入口之前；没有复现原失败。按协议SIGINT，不算原生通过或长门禁 |
| 增加主运行循环活动，310.398s后中断 | 0活动drop；运行循环在若干慢事件中已离开等待、尚未进入播放器回调 | 排查推进到回调前事件处理边界（也包括尚未单独测量的屏幕变更通知刷新）；没有调用栈，不判定具体系统函数、CPU抢占或原失败根因。因发现唤醒保护到期，提前终止并保存环境原因 |

这里的refresh耗时仅指本次cadence回调内的刷新，不包含通知处理或pause setter触发的刷新；不能据此排除所有`refreshCadence`路径。独立主队列探针只有离散采样，不能据一次响应证明整个间隔不忙。诊断本身可能改变时序，不将未复现当作修复证明。也不据这些结果增加缓存、改变catch-up策略或放宽零丢帧门限。Apple文档将显示链回调频率描述为尽力满足的请求，并非硬实时期限（[preferredFrameRateRange](https://developer.apple.com/documentation/quartzcore/cadisplaylink/preferredframeraterange)）；这不免除现有本机验收要求。

## 已确认并修正的验证工具缺陷

`run_with_display_awake.py` 原先使用 `caffeinate -d -i -u -t 240 -w <ownedPID>`。宿主 `pmset -g assertions` 在约217s明确显示display/system断言将在22s后释放；240s之后这两项确已消失，而测试仍在执行。长播计划为1200s，因此后半程环境不满足保护假设。该问题不能解释55s的原始丢帧。

移除固定 `-t 240`，保留owned PID约束与原有正常/异常/信号清理。`-u`使用系统默认短暂唤醒；`-d/-i`持续到owned命令结束。虚拟300s命令回归先失败（保护丢失返回91）再通过；真实1s/8s两次读回显示system/display断言均无到期时间，短暂user-active断言按期消失。进程退出清理检查单独记录，不修改系统睡眠设置。

## 验证状态

- 边界断言RED1→GREEN13/13；首次GREEN编译字段错位失败保留，纠正后通过。
- 运行循环断言RED1→GREEN13/13；旧四项时序校验兼容，新增边界/运行循环校验先拒绝失败再通过。
- Python播放工具209/209；迁移夹具4/4、源码镜像1/1、发现iOS680/macOS676。
- 修正EOF观察同步后，完整macOS675/675、零失败/跳过；462份源码与5份二进制保持一致。独立无探针短播30.029463s、770帧，活动drop/order0，最大落后23.125ms，释放检查通过；关闭后另有1次enqueueTimeout，单独记录。
- 同版本无探针长播已通过：1201.167654s、28,915帧，活动drop/order0，最大落后48.250ms，关闭后释放检查通过。连续性观察基于真实解码及纹理提交计数、静音音频素材，不能代替物理显示/扬声器测量。

协议：[回调边界](../../../tool/playback_benchmark/display-cadence-boundary-protocol.md)、[运行循环边界](../../../tool/playback_benchmark/display-runloop-boundary-protocol.md)、[修正后门禁](../../../tool/playback_benchmark/display-awake-final-gates-protocol.md)。候选默认关闭、生产不准入、整体下游资源边界未证明。当前共享iOS源码未变，不新增iOS运行声明，后续目标仍为iPhone 18 Pro Max。

## 完整套件暴露的EOF观察竞态

修正唤醒保护后的首次完整套件675项：674通过、1失败，无跳过；462份源码与5份二进制身份保持。失败精确位于资源观察测试的公开completed次数断言：内部状态已completed，但公开回调当时尚未到达（0而不是1）。七种配置后续completed附件均记录恰好1次、pending=false、无failure；失败报告未指明具体哪种配置，不能补猜。

源码确认`YlApplePlayerHost.send`将`callbacks.onState`放入异步outbound FIFO，内部状态与公开消息到达没有同步完成契约。测试现在在原`expectedSeconds + 10`期限内等待两者，再保留exactly-one断言；没有延长超时、忽略缺失事件或修改生产回调行为。初次全套失败作为真实RED保留，定向复验后以新身份重跑完整套件。


## 本轮完成边界

本机R5完整功能回归与独立连续播放门禁已完成。同版本无探针长播已通过：1201.167654s、28,915帧，活动drop/order0，最大落后48.250ms，关闭后释放检查通过。长播关闭阶段另有1次enqueueTimeout，活动阶段计数保持0。音频时钟相对单调壁钟累计快1566.471ms，符合原协议±5s门限；这不是物理音画偏移测量。原始失败、两次故意中断诊断、EOF同步修复前的完整失败均保留，没有重复运行同条件失败来求通过。

显示延迟已缩小到cadence回调入口之前的等待/事件处理区间；先前55s失败的具体调用栈仍未捕获，不能宣称该根因已修复。实际修复的是验证工具保护生命周期和测试公开事件同步边界。A5资源上界不准入、R4设备/物理输出缺口仍开放，整个P08不标为完成。

[可回放原始证据与最终身份](../../../tool/playback_benchmark/macos-display-cadence-boundary-observations.json)包含初始失败与修正后验证，所有候选默认/生产准入/下游资源上界标志继续false。
