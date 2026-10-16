# P04 Task 3A：直播模式源码审计与运行时契约

2026-10-11 Task3B进度：下述Dart值/可空状态/可选SPI/Session入口已实现；原生桥接、
默认live策略迁移、后端事务及数值验收仍未实现。下文“尚未实现”描述Task3A固定
审计时点，不能覆盖此进度。结算仅以身份判断过期，同会话failed不应覆盖原始拒绝
或已经提交的ACK；新命令仍拒绝failed会话。详见[P04执行报告](../reports/2026-09-26-remaining-04-abr-live.md)。

本节完成既有 P04 Task 3 第一项的设计交付，作为后续代码切片的实施基线。
**下面的新接口尚未实现，不是当前 API，也不证明 CAP-LIVE 通过。**
审计固定在提交 `e6112e15e6d70febcdc88d790b4f4bb69a2e1c6e`；并行字幕/显示跟踪的
工作区变化不纳入结论。源文件路径、Git blob、SHA256 和关键代码行归档于
[源码证据](../reports/evidence/2026-10-11-live-mode-audit/source-audit.json)。

依据：[需求 REQ-08 / CAP-LIVE](2026-09-20-playback-expansion-requirements.md)、
[P04 Task 3](../plans/2026-09-26-remaining-04-abr-live.md)。目标是 HLS、HTTP-FLV、
普通 RTMP 的流畅优先/低延迟切换与默认流畅优先。继承既有音频所有权、会话代际、
网络凭据/重试、固定档位、硬解和保护输出要求；不修改最低系统版本，不新增商业 SDK。
本轮仅源代码审计、契约和验证用例清单，无设备、服务器、网络或原生构建。

## 1. 当前实现与实际缺口

下表的 A/D/P 编号对应证据 JSON 内的 source ID。所有数值是代码配置，非实测SLO。

| 路径 | 已存在的 Load 行为 | 运行时切换缺口 |
|---|---|---|
| 公共 Dart（P1–P6） | `YlLoadOptions.bufferStrategy` 默认 automatic；有 lowLatency/smoothPlayback/bounded | Session、可选 SPI、operation 和状态均无直播模式；不能从一个 Load 选项推导支持运行时切换 |
| Apple HLS / AVPlayer（A1/A2） | lowLatency→2s、smoothPlayback→stable/30s、automatic→10s preferredForwardBufferDuration；lowLatency关闭自动等待；stable且无自定义HLS loader时通过rate启动，其余playImmediately | 无模式命令；等待策略、首播/恢复入口和重建配置必须一起更新，单写preferredForwardBufferDuration会留下旧行为 |
| Apple HTTP-FLV / managed（A3/A4） | lowLatency的network/audio/packet额度4/1/2MiB；stable为16/4/8MiB；automatic为8/2/4MiB；bounded优先使用独立plan | session持有let configuration/bufferBudget，各pipeline在构造时接收；不是可就地替换的完整策略。HTTP-FLV seekToLiveEdge明确拒绝，不可冒充可seek的直播窗口 |
| Apple RTMP（A4–A6） | 普通RTMP进入managed路径；seekToLiveEdge触发显式重连；恢复budget随recipe保留，瞬态恢复最多3次，500/1000/2000ms | 传输Set Buffer Length写死1000ms，未接模式。不能把协议消息、固定工作区或重连成功当作低延迟证据 |
| Android HLS / HTTP-FLV（D1–D5） | lowLatency→1/5s、24MiB；stable→15/50s、64或96MiB；automatic→5/20s、48MiB，再按设备/源分档限制 | loadControl有内部updateProfile，但无公开事务。healthMonitor独立做HLS追速/追边、HTTP-FLV积压重连；运行时需联动策略与恢复、内存压力状态 |
| Android RTMP（D5–D8） | Media3路径接入独立RTMP传输/恢复；RTMP主动跳过通用healthMonitor。瞬态恢复最多3次，500/1000/2000ms；Set Buffer Length固定1000ms | 调整通用HLS健康策略不能覆盖RTMP；RTMP恢复代际/预算和传输积压需专门实现 |

Android的设备约束可进一步缩小上表目标。`YlAdaptiveLoadControl`明确是调度目标，
不是硬内存上限；其updateProfile还会清除pressureReduced，因此未来模式更新必须
在内存压力仍有效时重新计算有效目标，不能无意恢复大预算。Apple AVPlayer的
preferred值同样不能用来宣称独立字节/时长准入上限已经执行。

Android HLS目前可能按目标offset追速到1.03或超过maxBuffer+3s时追边，HTTP-FLV
超过maxBuffer+3s走重连；managed网络分支禁止绕过请求owner重开。已有行为不等于
两模式已分离，也不能把source classification中的HLS/FLV标签当成真正live证据。
运行时准入必须使用当前已提交会话的有效live时间轴/协议信息。

两端RTMP目前拒绝bounded、managed HTTP策略及RTMPS。新模式不会放开这些边界。
`liveOffset`、buffered duration、isAtLiveEdge和服务端Buffer Length都不等于端到端延迟。

## 2. 后续公共契约（待实现的精确名称）

```dart
enum YlLivePlaybackMode { smoothPlayback, lowLatency }

// 位于 YlPlaybackSession；成功仅表示模式事务已提交。
Future<void> setLivePlaybackMode(YlLivePlaybackMode mode);

// 单独的可选 SPI，避免要求全部旧 adapter 实现新方法。
abstract interface class YlLivePlaybackPlatformPlayer {
  Future<void> setLivePlaybackMode(
    YlPlaybackSessionId sessionId,
    YlLivePlaybackMode mode,
  );
}

// YlPlayerOperation 末尾追加 livePlaybackMode，保留既有序号。
// YlPlayerState 追加可空字段 livePlayback，默认 null。
final class YlLivePlaybackState {
  YlLivePlaybackState({
    required this.mode,
    required List<YlLivePlaybackMode> switchableModes,
  });
  final YlLivePlaybackMode mode;
  final List<YlLivePlaybackMode> switchableModes;
}
```

`switchableModes`需不可变、无重复；可以为空（已知Load模式但此会话不能切换）。
状态只发布**已提交**模式，不把请求中目标当作生效。`null`表示无模式证据，涵盖idle、
非live、尚未识别、旧adapter和已stop；不得在UI显示成lowLatency或smoothPlayback。
新状态参与构造验证、copyWith显式null语义、equality/hash以及snapshot传输；delta不
携带此字段时保留原值，模式改变必须发完整snapshot。不得改写字幕/其他状态。

准入三道门：可选SPI + player operation + 当前会话switchableModes包含目标。
先校验当前session，再查能力；无SPI/能力/会话支持返回既有`policy.unsupported`，
失效session返回`session.stale`，dispose返回`player.disposed`。相同模式在有效且支持
的会话上幂等成功，不打开新连接、不补充恢复预算；不绕过能力检查。失败保留既有
code/category/scope/retryable/diagnosticId，不回显媒体地址、原生堆栈或服务响应。

### 默认行为与bounded

后续支持此契约的后端：已确认live时，automatic解析为smoothPlayback；显式
lowLatency/smoothPlayback按指定模式。公开`YlLoadOptions`构造默认仍automatic，
VOD行为不改变。automatic→smooth是**将来的行为变更**，要测默认与显式流畅策略
等价，不能把当前automatic历史记录重标为smooth。旧adapter保持原Load行为、状态null、
切换拒绝，UI提示当前会话不支持；阶段支持矩阵列出差异，直到三端迁移完成。

bounded仍是独立硬约束，不能由模式替换、删除或改成提示。对已准入的live bounded
会话，后续实现须保留原min/max/bytes、buffer owner和计数；默认倾向smooth，任何
低延迟目标都受同一硬约束裁剪。做不到约束与模式同时生效就不发布可切模式/拒绝
命令，不能放宽预算后ACK。该规则不新增当前被拒绝的协议/后端组合，也不引入第二套
公共预算字段。hardwareRequired、固定轨道/caps、DRM输出和网络策略同样不得改变。

## 3. 命令事务与状态屏障

1. 接收：Dart校验session及能力，在await成功/失败后再次检查session，旧会话回包
   只能结算旧调用。原生在自己持有的session owner上再校验；入口校验不是提交校验。
2. 排序：同一session的模式变更按原生接收顺序逐个执行，不采用“后请求直接覆盖”。
   每条获接纳命令都有独立settlement；幂等只允许在轮到它执行时对当前模式比较。
   与seek/轨道/caps的提交进入共同有序通道，保留现有命令契约，不能新增旁路线程改配置。
   stop/dispose/load替换使旧代际失效并取消待执行模式命令，不在慢候选后排队等待。
3. 准备：构造包含协议、模式、原限制、播放/暂停意图、用户速率、恢复owner的候选策略。
   旧策略在候选验证完成前继续生效。每个回调携带session和内部transaction generation，
   不能只用同一个URL判断身份。每player最多接纳32条尚未结算模式命令，超出以resource.exhausted拒绝且不排队；
   这是工程队列上限，不是性能SLO。候选资源继续受既有owner约束，不能无限积压。
4. 原子提交：在owner队列上复核代际；同时安装策略和相关buffer/recovery配置，发布
   同session且revision递增的完整snapshot。Dart适配器观察到对应已提交状态后才完成
   Future；原生方法返回/属性setter返回不单独构成跨通道状态屏障。
5. 重建：允许内部候选重建，但公开session ID不变；旧输出仍受音频/纹理/保护视图
   所有权约束，候选不得提前发声或发布新模式。恢复计数和取消token不能因切模式归零。
   需要重新访问网络时沿用原请求凭据过滤、请求owner、已有retry预算和准入规则。
6. 失败：提交前撤销候选、释放其资源，旧模式/意图继续有效；无新模式ACK。如果底层
   操作无法恢复旧策略，就不能宣称“失败且原播放完整保留”：先安全停止受影响输出，
   发布明确session失败并拒绝命令。未能完成取消/释放不能用超时Future伪造资源已清理。
7. ACK边界：证明策略已安装且其约束可执行，不等待/宣称首帧、无卡顿、清空积压或
   达到延迟SLO。ACK后的流中断是独立session事件，不能反向改写已成功命令。

模式命令成功后如果快速进入另一个模式，适配器仍需用匹配的命令完成信息和revision
屏障结算每条Future，不能要求“当前mode必须一直等于旧目标”。这要求桥接返回提交
身份，不可仅轮询最新状态值。错误命令不消耗一次“成功模式变更”，不污染恢复意图。

### 桥接载荷（待实现）

两端分别新增同结构的`AppleLivePlaybackMode` / `AndroidLivePlaybackMode`，值顺序为
smoothPlayback、lowLatency；可选operation追加到各端已有enum末尾。
新增`AppleLivePlaybackModeCommand` / `AndroidLivePlaybackModeCommand`：
`String sessionId; int requestId; <Platform>LivePlaybackMode mode;`。
requestId为适配器实例内递增正signed64，零/重复/倒退明确拒绝；耗尽时拒绝再发，不能回绕。
新增异步host方法`setLivePlaybackMode(command)`返回
`<Platform>LivePlaybackModeReply { String sessionId; int requestId; int committedRevision; }`。
reply与状态必须同session，revision可等于已存在的匹配snapshot（幂等），其余必须递增。
适配器保存命令对应的已提交snapshot屏障记录，迟到reply不拿新会话状态补齐。

新增`<Platform>LivePlaybackStateMessage { <Platform>LivePlaybackMode mode;
List<<Platform>LivePlaybackMode> switchableModes; }`，snapshot末尾增加nullable字段。
这是schema演进：两端Pigeon源码、生成物、native编码、Dart解码、版本协商/兼容拒绝
必须同一代码切片交付；实施时从当时HEAD分配下一个schema版本，不硬写本次审计的旧值。
新增类型追加而不重排旧codec tag。未完成握手不得advertise operation。

## 4. 协议执行要求

| 场景 | smoothPlayback | lowLatency | 共同限制 |
|---|---|---|---|
| HLS | 应用流畅策略与恢复配置，按冻结的停顿目标验收 | 应用低延迟策略；仅在当前窗口有效且条件满足时追速/追实时 | 用户显式非1倍速不能被追速覆盖；绝对时间seek与seekToLiveEdge语义分离；不能用公共load偷换命令 |
| HTTP-FLV | 有界缓存与连续输出，不虚构seekable窗口 | 追赶若需重开，必须候选验证、音视频代际隔离、预算与确认 | 不能直接调用Apple已明确拒绝的HTTP-FLV seekToLiveEdge，也不能复用一个offset作为真实延迟 |
| RTMP | 保留当前传输/会话恢复约束，提供受控积压处理 | 单独实现关键帧/音频同步或重开策略；协议Buffer Length不构成完成 | 通用HLS healthMonitor不适用；显式切换/自动恢复不能重置会话预算、无限刷新连接或暗中放开RTMPS |
| 暂停/后台 | 保留用户意图和模式，执行当前预算 | 不擅自开始播放；恢复时按当前模式处理旧积压 | 后台无可执行owner时不ACK“已生效”，保持可取消待处理或明确拒绝；stop/dispose优先失效 |

表中不预填数值SLO：协议/设备/构建相同的实际基线和P08冻结目标仍是前置条件。
第一轮代码可以先交付Dart契约/旧adapter拒绝；不能仅用Load参数转换就打开任一原生
运行时能力。继而先完成HLS事务，再分别实现HTTP-FLV和RTMP专属路径，每行独立验收。

## 5. 必须先写的验证用例与交付拆分

| ID | 条件与动作 | 必须观察的结果 | 可否离线 |
|---|---|---|---|
| LM-01 | 旧adapter、有SPI但无operation、operation但无SPI | policy.unsupported；没有调用/伪造新模式 | Dart可控后端 |
| LM-02 | VOD、未识别live、switchableModes不含目标 | 拒绝，不改Load策略或播放状态 | Dart/原生可控后端 |
| LM-03 | live automatic、显式smooth、显式low；VOD automatic | 新后端默认smooth且显式优先；VOD不变；旧后端null | 纯映射及后端测试 |
| LM-04 | low→smooth→low，首命令ACK延迟，中间命令失败 | 顺序、每条settlement和snapshot身份正确，失败不覆盖上次成功 | 可控队列/屏障 |
| LM-05 | 相同模式命令、bounded/硬解/fixed/caps/DRM | 幂等无重连；约束保留；不支持组合明确拒绝 | 可控策略/owner |
| LM-06 | 候选准备/安装/发布前故障、取消或预算耗尽 | 候选清理；可回滚则旧模式有效；不可恢复则明确session失败 | 故障注入 |
| LM-07 | seek/caps/切模式交错，随后load/stop/dispose | 同会话提交顺序；旧回包无新状态、旧音频/帧/纹理泄漏 | 可控后端+原生 |
| LM-08 | 暂停/后台期间命令与恢复，内存压力仍有效 | 意图不变、无假ACK、预算不放大，恢复计数不重置 | 生命周期注入+实机 |
| LM-09 | reply先到、snapshot先到、新模式覆盖旧snapshot | 每条Future按requestId/revision屏障结算；重复/旧epoch拒绝 | 桥接双端测试 |
| LM-10 | HLS/HTTP-FLV/RTMP同源弱网两次切换和断流恢复 | 画面/声音推进、策略真实执行、积压有界、无降fixed/宽caps | 需要测试环境 |
| LM-11 | 有/无可信源时钟、多轮冷暖缓存 | 延迟仅有时钟才量化；保留失败/超时并独立冻结SLO | 需要实测 |

Task3A本轮只交付审计与上述契约。Task3B先做公共值/可选SPI/拒绝与屏障测试，
Task3C做双端桥接和HLS事务，Task3D做FLV/RTMP恢复与预算，Task3E做三协议实际测量。
这些切片是现有Task3的实施顺序，不改变其验收范围。当前平台支持表不增加通过行。

## 2026-10-16 实施补充（保留上文固定审计基线）

双端私有协议现为 schema 6。`LivePlaybackStateMessage` 增加私有可空正 signed64
`committedRequestId`；首次接受的该请求完整快照 revision 必须与 reply 的
`committedRevision` 完全一致。后续 metrics/模式快照不抹掉已有配对证据。
每个适配器最多保留 32 条待配对请求及 32 个未返回原生调用；首个半边抵达后
五秒内缺少另一半则 protocol.mismatch，生命周期取消优先结束等待。此字段不增加
Dart 公共状态 API。Pigeon 28 的枚举提升由生成脚本后处理修复，旧 factory 标签不变。

HLS 回看恢复用户速率并关闭自动追实时，只有显式 seekToLiveEdge 重新授权。
Apple 的固定预算流水线通过同会话候选提交切模式；排队控制必须在执行时解析当前
后端。RTMP 的模式刷新与断线恢复共用会话额度，暂停切换不启动输出，实际恢复只在
后续播放需求满足时执行。无设备策略验证不等于三协议实播或性能验收。
