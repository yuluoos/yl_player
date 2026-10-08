# Apple fallback 音频输出完成契约

日期：2026-10-08。承接 P08、`6e538f7` 的失败回收原型。本文明确现有生产边界及下一实现的准入条件；不将实验候选标记为已接入，也不新增商业 SDK。

## 1. 本次落地范围

播放结束查询使用 `YlAudioRenderer.hasPendingPlayback`，经 `YlAudioPipeline.Resource` 传递给 session。它表示**当前 completion generation 中还有已接纳、尚未收到输出完成通知的缓冲**，由 `scheduledBufferCount > 0` 决定。它不是物理声卡探针，也不是跨 reset 的同步屏障。

`scheduledDurationUs`、`scheduledBytes` 继续用于排队统计与背压；时长为零不再独自证明排空。真实输出仍用 `.dataPlayedBack` 回调；本次没有提前释放 PCM、使用原型期限代替回调，或改变媒体时钟算法。

## 2. 三种边界不可混用

| 边界 | 当前依据 | 可以据此做什么 | 不能单独据此做什么 |
|---|---|---|---|
| 节点已经渲染 | player sample time / `.dataRendered` | 观察渲染进度；现有媒体时钟跟随并限制在已排入区间 | 声称设备输出已经结束、让 session 提前 completed |
| 输出完成通知 | 当前代 `.dataPlayedBack` | 当前实现释放一次性 callback 的 payload/预算，扣减待完成缓冲；播放中推进已有 position 上界 | 将通知到达的精确时刻当作扬声器输出时刻，或据跨线程先后证明物理误差 |
| 当前代排空 | 当前代待完成缓冲数归零 | 配合 demux EOF、无待入队音频包、视频解码及呈现排空，允许 session 结束 | 证明旧代所有系统对象已释放、全局无泄漏或整机输出安静 |

Apple 将 [dataRendered](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/datarendered) 定义为节点渲染通知，未包含下游处理延迟；[dataPlayedBack](https://developer.apple.com/documentation/avfaudio/avaudioplayernodecompletioncallbacktype/dataplayedback) 考虑下游与设备延迟。它们提供不同语义，系统通知的派发顺序不是物理输出测量。

本机 SDK `AVAudioNode.h` 将 `lastRenderTime` 描述为最近渲染对应的时间；`outputPresentationLatency` 为下游最大呈现延迟，零可能未知，图改变时可能变化；`AVAudioPlayerNode.h` 中用这些时间追踪剩余渲染量的说明位于 **offline rendering** 段落。不能把该段解释为任意实时路由均具备设备播放游标。API 文档和本地头文件的适用范围都必须保留。

## 3. 状态规则

- 接纳缓冲后，待完成计数增加一次；尚未接纳或 stale-generation 的包不能增加。
- 当前代有效输出完成通知只扣减一次，且不能扣减另一个缓冲。node sample time 即使超过最后 PTS，也不替代该通知。
- 暂停禁止新的媒体位置推进，但已在途的输出完成通知仍可释放容量及归零计数。时间戳缺失不等于完成，也不需要伪造为零。
- 倍速已经反映在 player timeline 中；不得再次乘速率。改变速率不能凭空生成完成通知。
- flush/reset/dispose 先隔离旧代，清理当前代逻辑状态，再执行已有输出停止/重置流程。延迟旧回调只能释放自己的持有，不能扣减新代。
- 时长未知/为零与字节数归零均不构成“没有已排入缓冲”的充分条件。零时长回归是合成边界输入，不代表已经观察到真实解码器输出此类 PCM。
- 无音频 renderer 时 session 的音频排空条件成立；其余 EOF、pending packet、视频和 playing 条件仍须满足。

## 4. 为什么不接入现有期限原型

`6e538f7` 的两组候选共有 72 次先于配对 reference 的通知到达，原先零容差门槛两组均失败。保留这个原始结论，不能重新命名为已通过；也不能把最多 0.133ms 的通知顺序差当成实际提前释放的物理证据。

“rendered 通知时刻 + 报告延迟 + 最大渲染帧数余量”仍需要建立以下证据链：输入缓冲末端在输出时基中的映射、处理器速率变化时的映射、已渲染尾部在 pause 后的进展、路由 epoch 与可靠延迟更新，以及可观测的设备输出进度。当前 production 的 node sample time、现有原型和静音双节点测量没有提供这条完整证据链。

因此当前可靠的**软件完成契约**继续依赖实际 `.dataPlayedBack`；“回调比较不完全等价”与“该候选绝对不安全”是不同结论。未来若修改准入指标，必须在新测量前说明语义与误差预算，保留旧失败，不允许用上次最大差值直接追加经验延迟。

## 5. 后续实现顺序与门槛

1. **分离责任，保持现有行为。** 将已渲染/资源可释放、媒体时钟、最终输出排空分别建模；初次适配仍由原 `playedBack` 路径提供信息，确保行为回归通过。不能让普通 rendered 通知直接扣除本契约的待播放计数。
2. **选择有文档依据的完成来源。** 优先验证是否能只在明确的最终音频边界保留系统完成通知，而将普通缓冲的资源生命周期单独处理。末尾 PCM 的确定、EOF 前后入队并发、短流及暂停期 EOF 必须有具体设计；零帧哨兵、插入静音或周期 reset 均不作为未经验证的捷径。该方向尚未实现/批准为生产替代，不预设其可行。
3. **验证背压和连续性。** 资源释放后仍在下游的音频不能无限累积；需要独立的时间/容量边界、时钟饥饿规则、断流恢复和新旧代隔离。必须覆盖 seek、切轨、rate、pause、EOF、route change、未知延迟和失效通知。
4. **验证实际收益。** 原生对象归属与长播资源验证、无 heap 干扰连续性、物理音画/设备矩阵各自计分；减少普通回调数量不自动证明内存有界。

第 1 节的当前代排空查询已落地；第 5 节第 1 项的职责拆分见下文。完成来源替代及其余验证仍为后续工作；整个系统计时器增长问题、长播和完整 P08 Task1/2 仍开放。


## 6. 双阶段通知与当前生产适配

新增内部 `YlAudioOutputCallbacks`：`resourcesReleased` 表示输出不再需要 renderer 持有 PCM；`playedBack` 表示当前软件播放完成边界。资源通知仅释放该缓冲的 PCM 捕获并扣减 renderer 字节计数；不能改变媒体位置、待播放时长/数量或 underrun。播放阶段的工作闭包只捕获 PTS/时长/generation 标量与账本 token（完成容器在资源阶段结束前仍持有 PCM），结束时间预算，再在同一状态锁内分别推进媒体位置、扣减待播放时长/数量并更新排空/underrun。暂停时仍允许回收，位置保持不变。

账本 token 同时由尚未释放的资源捕获和播放元数据持有。资源先完成时，即使 PCM 已释放，**全局字节与时间预算仍保守保留到 playedBack**；播放先到时，完成对象会一次性接纳尚未执行的资源工作。令 token 过早缩减字节或结束 queued timing 都不属于本次实现。该选择可能延后容量恢复，目的在于为后续通知来源实验保留现有总预算约束。

`YlAudioCompletionGroup` 为双阶段工作提供一个独立完成对象，两个可清空闭包共享 renderer 已有的锁；不建立中央 pending 表或逐缓冲新锁/计时器。任意重复通知只领取各阶段一次，调用与捕获释放均在锁外。并发时，另一线程已经领取的资源工作可能尚未执行完：播放通知不是该线程的执行屏障，资源闭包仍保有自己的 PCM/token，旧代回调各自遵守 renderer generation 检查。所有通知持有都被丢弃时，剩余捕获随该缓冲的完成对象释放。

`YlAudioOutputDriving` 保留现有 schedule completion 入口，并新增有默认桥接实现的双阶段入口；默认桥接把 `playedBack` 传给旧入口。实际 `YlSystemAudioOutput` 仍从 `.dataPlayedBack` 发出通知，因此当前生产没有提前资源通知，也没有添加期限、渲染回调或最终尾部哨兵。已有单回调测试输出保持兼容；只有专用测试输出分别驱动两个阶段来验证边界。

这一步增加事件元数据和闭包，不宣称分配更少、系统完成外壳变小或整体内存改善。下一步才验证明确最终音频边界的通知策略，以及短流、EOF 并发、pause/rate/seek/route 和背压；此前的期限原型失败仍有效。
