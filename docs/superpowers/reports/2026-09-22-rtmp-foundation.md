# RTMP 基础阶段实施与受控验收

基线提交 `eee8689`（`feat: add DASH playback and bounded script source resolution`）；本批实现、测试与报告一并提交。依据[实施计划](../plans/2026-09-22-rtmp-foundation.md)和[已授权需求](../specs/2026-09-20-playback-expansion-requirements.md)。三端受控应用验收、整体阶段复审及最终定向复审已完成，没有 Critical/Important 问题；保留下面明确列出的非阻塞工具及性能待办。

## 范围与状态

| 工作 | 当前证据 | 尚未证明 |
|---|---|---|
| Dart 源契约与安全错误 | 123 项定向测试通过；URI 不透明百分号字节修复另有 16 项通过；独立规格及质量复核通过 | 原生播放由下两行负责 |
| Android RTMP 接收与 Media3 FLV 接入 | 广泛定向 JVM 门槛 141 项通过；需求等待计时修复 14 项通过；首次复核修复 34 项及 Dart 错误映射 12 项通过；播放器暂停补充修复 23 项通过，独立复核通过 | 物理设备、最低系统与真实 OS 前后台；应用验收见下行 |
| Apple RTMP 接收与 custom AVIO 接入 | macOS/iOS 自包含原生测试各 36 项通过；格式错误码修复后相关 5 项各通过；Dart 错误映射 12 项通过；暂停、工程设置及恢复交接修复通过定向回归，独立复核通过 | 物理设备、最低系统与性能；应用验收见下行 |
| 三端公共 API 验收 | macOS 6 项、iOS Simulator 6 项、冷启动 Android Emulator 6 项通过；macOS resolver 定向 2 项通过 | 实际 OS 前后台、应用层租约转移后回滚、物理/最低系统及长期质量仍未证明 |

以上是不同阶段的覆盖门槛，包含重复用例，不能相加作为唯一测试总数。Android 首轮复核的 34 项包含 extractor 4、readiness 4、protocol 13、lifecycle 3、control 7、flow control 3；零失败、错误或跳过。源码和相关测试已编译。

本批限定普通 TCP `rtmp://`、simple v3 握手、经典 AVC 视频与可选 AAC 音频。部署下限不变，不增加商业 SDK，也不替换现有禁用网络的 FFmpeg 制品。RTMPS、增强 RTMP、隧道、发布、userinfo 认证、重定向、DVR、纯音频及其他编码未覆盖。

`YlNetworkSource` 保留公共源形式；automatic/flv 与 automatic/live 进入 RTMP 路线。HTTP 请求头或凭据、HTTP managed 策略、严格 bounded 缓冲、VOD、非零初始位置在联网前拒绝。运行时所有 `seekTo`（含零）均拒绝；`seekToLiveEdge` 重新打开当前直播。三种非严格缓冲模式只是调优目标，没有新增延迟承诺。

## 资源、取消与恢复约束

- 建连准备的绝对期限为 10 秒，贯穿 DNS、连接、握手、命令、AVC 配置和首个有效视频关键帧；Apple 还须覆盖 AVIO 流信息发现。
- 建立后的无媒体期限为 15 秒累计主动读需求时间；消费者暂停或背压期间暂停计时。控制、元数据、配置和 EOS 消息不重置期限，实际编码媒体才重置。
- 最多 32 个 chunk 状态；媒体消息 4 MiB、控制/AMF 消息 64 KiB、在途重组 8 MiB、待发送控制字节 64 KiB；AMF 深度 8、条目 256、字符串 16 KiB。以上是内部源工作集限额，不代表严格 `buffer.bounded` 策略已实现。
- 初次候选只尝试一次，失败保留原会话。提交后的自动故障重连最多三次，延迟 500/1000/2000 ms，成功出帧不会补充次数。显式刷新及生命周期恢复不消耗或补充此预算；其瞬时失败只能使用剩余次数。
- 每次重连建立新解析与解码时间域，保留公共 session identity。跨轨正常交错允许；单轨倒退超过 2 秒或 32 位回绕触发有限恢复。
- FLV 只声明启动时真实配置的轨道。后续新增 AAC 或改变 AVC/AAC 配置明确返回 `container.rtmp_track_layout_changed`，提示重新加载；相同配置重复允许。格式错误优先永久拒绝，合法配置伴随时间戳重置则先进入新时间域恢复。
- Apple 当前实现提前在既有账本预留 32 MiB 的源工作集，覆盖解析、启动/输出、复制、控制及接收缓冲；读取所有者释放数据后才归还预算。这不是进程 RSS 实测，也不是严格 bounded 策略支持声明。
- Android API 24 的系统 DNS 最多占用两个全局查询位置，没有无界队列。取消立即结束调用方等待，但不能保证终止系统 DNS 线程；位置直到系统调用实际返回才释放。

安全错误区分建立阶段失败、播放断连、服务器明确拒绝、协议不支持、轨道配置变化与策略不支持。服务器原始文字、URI、凭据不进入提示。保留既有 session 与 diagnosticId，未扩展 wire schema。

## 独立对端证据

对端为 [MediaMTX v1.21.1](https://github.com/bluenviron/mediamtx/releases/tag/v1.21.1)，发布提交 `0482559`。只监听本机 `127.0.0.1:19350`；关闭其他协议、管理与指标服务。官方校验清单验证通过后执行，测试结束由拥有者关闭服务和发布进程。

- darwin_arm64 发布归档 SHA256：`25e20ed41611f1f3103b8359585210b29b11b69fa0d9e11bd11b92f7bbcb42ef`。
- 校验清单 SHA256：`d8348d6919fb6124576d971a3a6c8d3f124d6af9b8945969a4fc8e0a7aca13cf`。
- 自有夹具 `tool/consumer_fixtures/apple_flutter/Resources/h264_aac.flv`：H.264 320×180 + AAC 48 kHz；SHA256 `cfe009b1b03b6cacf4ae9f037eed4441a32b99508d4fabccb429bea439cf570b`。

Android 原生接收器 → 固定 Media3 1.11.0 FlvExtractor 已从独立对端产出 20 个 AVC、37 个 AAC 样本；纯视频另产出 20 个 AVC 样本，没有虚假音轨。所有声明轨道都有格式，时间线不可 seek、长度未知。这些是提取器证据；应用首帧证据另列于下文。

持续传输检查在 16,600 ms 内读取 8,389,423 FLV 输出字节，实际 RTMP 输入 8,385,565 字节；对端确认窗口 2,500,000 字节，累计 ACK 7,500,000 字节，跨过三个窗口后仍继续收流。为得到足量测试数据，测试发布器将自有夹具转为 4 Mbit/s CBR；系统 FFmpeg/libx264 仅作测试工具，不进入产品依赖。

MediaMTX 的不存在流用例在客户端观察为建立期间 TCP 关闭，没有收到明确 AMF 拒绝，因此报告 `network.rtmp_handshake_failed`。不能根据服务端日志推断客户端不存在的拒绝消息；永久 `network.rtmp_stream_unavailable` 另由受控 AMF 拒绝测试验证。

## 测试过程中的修正

Apple 连接测试首次运行的监听器辅助代码在启动后才设置处理器，失败发生在产品断言之前，因此这次失败不计作产品回归证据。自动审批拒绝了为重跑失败基线而临时替换未提交源文件的操作，理由是可能覆盖现有工作；实现保留，改为修正辅助代码并继续验证。最终自包含原生测试两端各 36 项通过。iOS 的该次记录有两条运行期线程优先级告警；符号化堆栈为既有 `YlHardwareVTSession.invalidate` → `VTDecompressionSessionWaitForAsynchronousFrames`，经 `YlVideoToolboxDecoder.dispose`、`YlVideoPipeline.discardDecoder`、`releaseMediaForStopOrDeactivation` 和 `demux.performSync` 在主线程同步排空。保留释放/租约顺序，单列性能待办，没有声明无告警或测得延迟上界。后续错误码对齐的定向 5 项两端通过且无运行期告警，不用此小范围结果抹去前述告警。

Apple 原生测试使用自包含的本机 RTMP 夹具；日常测试不依赖临时目录中的外部服务。另有独立 MediaMTX 运行记录：macOS 与指定 iOS 27 模拟器各 35 项通过，覆盖真实 H.264/AAC → custom AVIO 开启及会话恢复。这些用例与自包含套件重叠，不能相加计算唯一总数。正式应用首帧另列于下文，不与这些原生用例合计。

复核发现的 Apple 暂停问题已添加真实托管会话与阻塞 AVIO 读取回归：暂停保留连接、解析栈和剩余等待额度，已预留的重连暂停执行，恢复不重复扣减，停止取消等待。修复另恢复普通应用工程的签名及可测试性设置，仅在测试命令/测试目标设置覆盖值。部分消息的 abort 测试现验证内存释放和后续 chunk 历史。相关 macOS 28 项、iOS 29 项通过；后者保留一条同类既有 VT 释放告警。

加强用例时，真实断流和公开 live-edge 刷新路径另外暴露已退役解码器的过期数据包错误：缺少资源的分支没有检查既有代际取消条件。窄范围修复后，最终 macOS 新增 4 项和既有停止/解码错误/读取取消 3 项、iOS 相同 7 项通过，零失败或跳过，以上最终记录没有运行期告警。普通工程设置分别有 12 个 iOS、18 个 macOS 配置值与基线一致，验证脚本测试 7 项通过。初期人工从主线程触发解码回调的测试不能作为真实断流证明，最终用例已改为对端关闭实际连接。

第二轮复核进一步发现快速暂停/播放可能在两次检查之间遗漏已预留的重连任务。确定性交错用例复现后，改为在同一个会话锁内完成“允许开启或保存同次恢复任务”的决定。macOS 与 iOS 的恢复及托管暂停用例各 12 项通过，零失败、跳过或运行期告警；同时覆盖过期/已销毁会话拒绝及重连额度不重复扣减。

应用验收首次运行另发现 Apple 宿主的通用 seekability 检查先于 RTMP 策略检查，使 `seekTo(0)` 返回 HTTP 的 `network.range_not_supported`。已在宿主和 coordinator 的意图修改前统一拒绝 RTMP 时间 seek，保留 HTTP-FLV 行为；原生 macOS 相关 8 项加最终可移植 HTTP 对照 1 项、iOS 8 项通过，独立复核通过。这些原生结果与下述应用验收分开计数。该 iOS 定向记录有三条 QoS 告警：两条为既有同步 VT 排空，另一条符号化为未修改的 HTTP MP4 检查 `YlByteRingBuffer.condition.wait → YlNetworkByteSource → AVIO → YlMp4CompatibilityInspector`。后者属于既有 HTTP 检查的独立性能待办，没有声称整个阶段无性能告警。

## 三端受控应用验收

维护入口为 `tool/rtmp_acceptance/run.py` 与 core example 的 `integration_test/rtmp_playback_test.dart`。顺序为 macOS → iOS → Android；macOS 使用显示唤醒 wrapper，Android 使用 `-no-snapshot -no-window -no-audio -gpu swiftshader` 冷启动指定 AVD，没有 wipe。对端和两个发布器均由本次命令持有并在结束时清理；端口冲突会失败，不按端口杀其他进程。代理只转发原始 RTMP 字节，最多 8 个读连接，每连接暂存上限 8 MiB，控制连接最多 4 个、头部 8 KiB；暂停时继续排空服务端数据，避免把服务端慢读超时误当作播放器故障。

| 平台 | 用例与实测 | 恢复和最终错误 |
|---|---|---|
| macOS 27.0 / 26A428 / arm64 | 6/6；AVC/AAC 23286→26432 ms，墙钟 3141 ms；AVC-only 1→3134 ms，墙钟 3128 ms | 三次新 presentation 输出；第四次断流 `network.retry_exhausted` |
| iPhone 18 Pro / iOS 27.0 arm64 Simulator | 6/6；AVC/AAC 83306→86510 ms，墙钟 3199 ms；AVC-only 1→3202 ms，墙钟 3199 ms | 三次新 presentation 输出；第四次断流 `network.retry_exhausted` |
| Android API 36 / arm64 / TV_64bit_1_5G_32G | 6/6；AVC/AAC 246→3260 ms，墙钟 3013 ms；AVC-only 116→3142 ms，墙钟 3026 ms | 三次 Media3 实际渲染帧对应当前公开 Surface；第四次断流 `network.rtmp_disconnected` |

各平台六项涵盖：挂载视图与匹配 session 的 firstFrame、AVC/AAC 及无虚假音轨的 AVC-only、live/不可 seek/未知长度、持续推进、停止后读连接关闭；8 组源/选项 assess/load 同码且不建连、运行时 seek 0/1 秒拒绝、拒绝后幸存源推进；缺失流候选保留；静默握手取消与新加载压过过期工作；阻塞输入下长暂停；三次自动恢复后第四次断流终止，以及实际重试安排后 Stop 取消退避。

长暂停在持续播放且缓冲耗尽后开始：macOS 播放位置=缓冲位置 61654 ms；iOS 为 121767 ms；Android 已是 buffering，播放 4213 ms、缓冲 4244 ms。暂停 20 秒分别暂存 950344、952690、918796 字节；无读连接关闭或新增，恢复后同一连接/会话继续推进超过 3 秒。Apple 重连计数保持 0；Android 公共计数字段保持 null，报告为未变化，不把缺失值推断成 0。Native 暂停/恢复测试另验证内部预算与剩余等待额度。

每次成功恢复后再断流，公开重试事件均严格为 index 1/2/3、delay 500/1000/2000 ms，独立对端只出现对应三个新连接；第四次断流等待后没有第四次重连。公共 firstFrame Future/event 是会话一次性的，未用旧 Future 充当恢复出帧证明。Apple 的 reconnectCount 在 `didAcceptPresentationFrame` 中增加，配合新时间域持续推进；Android 计数在安排重试时增加，因此另用 example debug-only AnalyticsListener 检查真实新帧、同 session 与当前公开 Surface。Apple 的 `metrics.mediaClockPosition` 为空，实际推进证据使用 `timeline.position`；Android 两者均有实际值。没有新增产品测试 channel 或修改公共首帧语义。

Apple 最终消息为 `The configured network retry attempts were exhausted. Check the connection and try again.`；Android 为 `The RTMP connection was lost during playback. Check the connection and try again.`。均保留 diagnosticId，断言消息非空且无 URI、主机或流路径。缺失流仍观察为 `network.rtmp_handshake_failed`；明确 AMF 拒绝另由 native 受控对端覆盖，不能根据 MediaMTX 日志改称 unavailable。

macOS 另有两次恢复定向复测（观察到 RetryScheduled 后 Stop；记录终止消息），均 1/1；Android 最后一次定向复测 1/1 将新帧检查加强为每次断流前计数基线后严格增加，实际为 0→1、1→2、2→3，并拒绝 observer error/overflow。这些与六项重叠，不相加为唯一用例数。最早 macOS 测试误以初始 0→直播时间戳跳变满足三秒推进，最终已改为非零基线、至少三秒墙钟与媒体推进并整组重跑。最早 seek 错码由上文 fix3 修正；暂停中途主动终止的那次运行不计为暂停失败或通过。

可选 resolver example 的 `rtmp_handoff_test.dart` 在 macOS 真实执行自有 JS → `toNetworkSource` → RTMP 挂载视图匹配会话首帧，1/1 通过；更正后的有效 app/playpath RTMP 转换与 RTMPS 拒绝契约另 1/1 通过。两目标连跑时第二个应用未连上调试服务、尚未进入断言；单项重跑通过。没有重新运行历史 26 项，也没有把 resolver 依赖加到 core。

缺失候选的公共用例证明 **候选失败后的同一公共会话保留与继续播放**，不直接证明解码租约转移后的恢复。Apple 缺失流在预检失败；Android 的独立对端另外可见旧读连接关闭、缺失流失败、旧源新连接继续读取，所以整组连接数是 15（Apple 为 14），不能误称隐藏自动重试。测试没有直接观察租约转移及原恢复操作完成回调，因此仍不升级为应用层 post-lease 回滚断言。另列的 Apple canonical AVIO 中断/继续读取测试与真实 coordinator 激活恢复测试，使用实际 AVIO/VideoToolbox、可控 texture/clock、一次显式恢复遭遇瞬态失败再自动恢复，并等待原操作完成；不是实际 OS 前后台应用转换。Android coordinator/readiness 回归使用真实 coordinator/gate 与 fake device engine，证明等待者和租约期限的状态控制；不声称它是实际设备回滚或前后台出帧。这些限制保留到后续矩阵。

定向 Dart 分析：core example 两个修改文件、resolver example 两个修改文件均无问题。当前 Apple canonical/example 夹具验证为 iOS 539 / macOS 455；Python harness 语法、发布归档与提取二进制一致性、`git diff --check` 通过。普通入口 source 与 lockfile 无修改；core macOS/iOS 和 resolver macOS 的生成配置已恢复 `FLUTTER_TARGET=lib/main.dart`。自有 iOS boot 与 Android cold boot 均已关闭；最终无 Task4 服务/发布器/构建进程，代理 active/heldBytes 归零。普通 PBX 签名默认值和冻结 native 制品未改动。完整复现命令、临时日志路径及失败/复测过程保留在 Task4 实施记录；维护脚本有独立使用说明。

最终阶段复审没有 Critical/Important 问题，提出四项工具/文档 Minor，已合并为一轮修正：runner 在成功、非零退出、超时及取消后都从有界清理路径写入带 outcome/cleanup 的收据；自有进程组的 TERM/KILL 与主进程是否仍存活解耦，无法证明退出时明确保留 cleanup incomplete；README 补充精确的 v1.21.1 darwin_arm64 资产 URL、SHA256、校验/提取及 FFmpeg 路径前提；公共源注释澄清非零初始位置与全部运行时 time seek（含零），并说明 live-edge fresh open。修复前的定向 Python 用例复现缺收据及残留子进程，最终 7/7 通过；一次最终 runner smoke 经真实 MediaMTX/代理解码 47 帧和 AAC，收据 success、cleanup complete、active/heldBytes 为零。未重跑原生或 Flutter 应用套件，没有下载/安装/替换制品或改动播放实现、VT/HTTP teardown；既有 QoS 披露与第 11 项裁定保留。同一审阅者的最终定向复审已确认四项均处理完成，未发现新的 Critical/Important 问题。

最终定向复审确认四项修正均已处理，另记录非阻塞 M5：`Proxy.reader` 的子任务循环复用了所有者变量名，导致已完成的 reader 任务引用仍留在集合中，直到本次 runner 退出。内存内探针显示三次 EOF 后 active 为零，但仍保留三个已完成任务；没有待执行任务或遗留连接。这是测试工具的引用清理待办，不是播放器连接泄漏；当前受控运行规模与已有退出清理证据仍有效。后续修复应使用独立的 reader 所有者变量并补 EOF 后集合归零回归。

## 后续范围与待办

测试工具 M5 的已完成任务引用清理、既有 VT/HTTP 性能待办，以及上述单列的实际 OS 前后台、租约转移后应用回滚和扩展设备/协议矩阵。

即便上述受控验收通过，也不代表物理 iOS、最低系统、Android 7/低内存/32 位、Intel macOS、长时间稳定性、AV 同步质量或外部订阅源可用性已验证。DRM 授权资源、完整杜比映射、DASH 全格式/ABR/字幕矩阵仍属于后续范围。

## 实施期间的裁定

以下按作出顺序记录，完整英文原文保留在实施账本中。

1. 本批先交付普通 TCP AVC/AAC 直播，明确拒绝 managed/bounded 组合，因为既有 HTTP 保证不能直接用于 RTMP。代价：部分源和策略需要后续阶段，总需求中的相应项保持未完成。
2. 自有 Swift/Kotlin 接收器复用现有 FLV 消费路径，避免替换已验证、禁用网络的 FFmpeg 制品。代价：两份协议实现需要持续维护，独立对端验收是必要门槛。
3. Android API 24 系统 DNS 最多允许两个在途查询，无无界排队；不能声称系统解析线程可终止。代价：系统查询长期不返回时可能暂时无法接纳新查询。
4. 时间戳跳变通过新解析时间域和有限重连预算处理，避免旧解码器混用时间基准。代价：反复跳变的流可能耗尽三次恢复并明确失败。
5. URI 规则针对 Dart 提供的序列化内容，因为 `Uri.parse` 已可能规范化输入。代价：调用方若需要原始文本拼写必须另行保存；原生不得再擅自解码重编码身份。
6. 初次候选只进行一次有限尝试，自动重连仅用于已提交会话，以兼容 Android 既有 15 秒候选激活期限并保留回滚。代价：首次瞬时失败需要调用方重试。
7. Apple 以自身绝对开启期限覆盖 AVIO 发现，因为没有等价的候选总期限。代价：极慢的初始元数据可能被拒绝，但不会无限等待。
8. 三次预算只计算自动故障恢复；成功的显式 live-edge 刷新、前台恢复和回滚重新开启不消耗或补充预算。代价：用户发起的重新开启没有全局次数上限，但每次均有单次期限和取消所有权。
9. 每个解析时间域固定启动轨道和编解码配置；后加 AAC 或配置变化返回明确重载错误，因为现有 FLV 路线不能安全地静默采用它们。代价：动态轨道流需重载或后续支持；相同配置重复允许。

10. RTMP 显式格式提示不兼容时统一为 `container.unsupported`，策略、意图、起始位置等组合仍为 `policy.unsupported`，让错误码对应实际原因。代价：依赖尚未发布的 Apple 合并策略错误码的调用方需调整。

11. 保留既有同步 VideoToolbox 释放与租约顺序，单独记录 iOS 的两条线程优先级告警，因为改为异步排空涉及更广的释放协议，而本轮没有测得卡死或延迟回归。代价：释放过程仍可能影响 UI 响应，需要后续性能测量；本批不宣称无告警或主线程延迟验收通过。

12. 测试 runner 的 M5 已完成任务引用清理作为非阻塞后续项保留：它只影响单次工具运行期间的已完成任务集合，当前验收连接数有限，退出后释放，且没有播放器连接或进程泄漏证据。代价：长时间高频反复建连会增加测试进程内存占用；不能据此宣称测试工具已经通过无限连接压力验证。
