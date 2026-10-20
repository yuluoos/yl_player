# 当前条件下剩余工程：实施与验收记录

状态：本轮实现与集中验证已完成；整体工程验收和发布准入仍未通过。基线 main `978c2c5c`，隔离分支 `codex/remaining-engineering`。保留现有投屏、媒体拆分、P07/P08 成果。本文不覆盖历史失败。

## P08 当前证据与采集修正

最新续查已包含音频锁隔离、TimeJumped 抑制、静音间隙推进、ready 通知、跨节点漂移及关闭单帧持有修复；不能以早期报告的待办重复实现。历史 119.084ms 原生未就绪内部原因仍开放，参见 2026-10-11 Thread Activity 报告。

本次修复 trace 采集器一次读取多行仅分析最后一行的问题；现在每条完整观测进入判断，64KiB 增量读取，单行上限 1MiB，截断明确失败。3 项 RED、20 项 GREEN。不是生产渲染修复。

生产源码快照 `9f19de49…` 下的本次 Debug 短诊断（在最终 HLS 回退修复前）：系统增量724帧、丢弃/损坏0/0；dispose 191.142ms；disposed及disposedLater账本均0；8组弱sample/reservation均消失，自有PID退出，冻结源码/产物不变。额外诊断已开启，不作为正式Profile长播或历史119ms根因闭环。原始记录来自 `/private/tmp/remaining-timed-short`，脱敏文本与内容哈希归档于本文同目录 evidence/2026-10-20-remaining-engineering/captures.tar.gz。

## P08 所有权契约核对

| 所有者 | 当前可核查边界 | 释放/反压 | 不覆盖 |
|---|---|---|---|
| Managed buffer ledger/scope | 每scope配置的字节与时长预算，分类token | 最后持有者释放，跨代token仍计费 | maxBytes=nil路径不是全局内存限额；系统复制/缓存不在此账本 |
| Timed video pump/window | 50ms未来窗口、最多3帧、至多1个待投递held帧 | native ready背压；退役撤销lease并清空held/window | 系统renderer内部队列/合成资源的容量 |
| Native sample/preview | 未来样本token随实际sample持有；一个paused preview共享reservation | flush、layer移除、preview清空；弱引用仅诊断 | 回调返回不能证明系统一切内部对象消失 |
| Audio renderer/completion group | 待播时长/PCM字节容量；每callback独立一次性捕获 | resource与playedBack分相；旧代callback不能改新代；完成后清空闭包 | AVAudioEngine持有的已执行completion包装、下游图/驱动缓存 |
| Terminal audio candidate | 单槽尾部、同代单向legacy回退；候选默认关闭 | EOF尾部playedBack，取消/stop隔离旧代 | 回退后长期下游保留上界；100ms回退阈值不是释放期限 |

本次复核未发现可用任意reset或扩大预算修复的有证据缺陷。系统资源A5仍未证明；有限次数heap平台期不能补足。维持 defaultEnabled=false、productionAdmission=false、downstreamBoundProven=false。

## P04 原生诊断

实际生产路径是 DASH→HLS 编译/HTTP 代理与 AVPlayer；没有可直接修补的项目自有 iOS ABR 吞吐估算器。新增 opt-in `testActualOwnedDashAdaptiveObservation` 与 `abr_accesslog.py`，采集实际后端的输出尺寸、播放完成、公开 access log、preferredPeakBitRate、forward buffer 和帧数。每次轮询释放测试纹理缓存；运行器绑定构建产物、素材和网络轨迹，核对自有进程身份并清理。默认全套测试不启动这项长诊断；只有显式环境参数运行，普通方法计数不当成真实播放证据。

先前两次实验使用 iPhone 18 Pro Max/iOS27 模拟器、同一原生构建、自有40秒素材与 down-and-recover-v1 轨迹：初始320→640→320，结束未升档，preferredPeakBitRate=0，forwardBuffer=10s。基准末段 observedBitrate=649907bit/s；仅将恢复 response latency 从40ms降至0ms的对照为749777bit/s，仍未升档。两个值均低于高档含音频声明764000bit/s，但 AVPlayer access log 不能证明私有决策原因，40ms也不是单独充分原因。未更改基准轨迹或生产策略。早期临时诊断曾保留采样纹理，故仅作ABR线索，不作为内存/性能资格；正式入口已逐次释放。

P04 iOS 恢复升档仍开放；诊断工具成功不等于 CAP-DASH/ABR 验收通过。正式入口实际运行退出0、播放完成，159个采样帧，尺寸320→640→320，自有PID退出、前后构建哈希一致；末段observedBitrate=769826bit/s仍未升档，进一步否定以低于声明码率的单一比较作为充分根因。该采样频率约4Hz，不是帧率/卡顿性能基准。统一验证结果见后续验收表。

## P07 解码帧对应

新增离线软件 HEVC 探针：保留原始 MP4 包 PTS/DTS，COPY_OPAQUE 传递包编号；独立 FFmpeg HEVC parser 从参数集/切片状态计算 POC，再随包穿过 B 帧重排和 EOF 排空。逐帧关联 BL、EL、原始 RPU 哈希，输出 active planar YUV 像素字节 SHA-256、几何、格式和图像类型。截断、缺帧、重复、错包/PTS/POC、非单图像输入明确拒绝；不将呈现序号冒充 POC。软件解码与 parser 属于同一 FFmpeg 实现，不是独立目标生成器。

公开 FEL 全片实测2,908对：BL3840×2160、EL1920×1080、yuv420p10le；2,114个包呈现顺序发生重排，全部 BL/EL PTS/POC及原始RPU关联通过。官方Sol Levante P5全片6,314帧也通过包/PTS/POC关联，无EL所以 `decoded_layer_pairing_verified=false`。素材哈希分别为 `419fc183988cb57b0cac2907a01d9f43b1a5ec34012b4c0655574d77678ee4fa`、`87fe0115f3002a621d2380a9f91852ef91a15854a446efe26de8744f77ef5346`。

新增 `stream_inventory.py --mapping`：按解码顺序解析显式 `vdr_rpu_id` / `prev_vdr_rpu_id`，绑定实际被引用的系数记录及来源包；同ID重定义仅覆盖该ID，未知ID、新epoch无历史或先按显示顺序排列的输入均拒绝。默认既有输出兼容；扩展模式schema3。FEL实测全部2,908条映射引用可解析，但该素材没有use_previous样本；复用/重定义仅由合成测试覆盖，不能写成真实use_previous像素验证。

`effective_metadata_resolved=false` 保留。以上不完成跨帧DM/trim的全部有效状态、完整适用CM/NLQ目标映射，也不证明独立参考、Dolby目标像素或原生DV信号。官方Sparks独立参考/帧生成对应未新增可核验证据，沿用既有未完成项。详见 [解码工具协议](../../../tool/dolby_reference/DECODED_ALIGNMENT.md)。

## 集中验收发现的回退修复

原生全套暴露真实 HLS 回退缺陷：固定流无法满足 Load 的宽高/码率限制时，旧 AV/HLS 引擎先被停用，然后构造候选才拒绝约束，导致旧 AVPlayerItem 被重建。现在在 willCommit 和资源交易前执行相同的固定流约束校验；构造端保留防御校验，失败候选仍由 open coordinator 取消和释放。新增强度更高的原生回归同时要求 willCommit=0、旧 item 身份不变、公开会话/播放意图/first-frame 不变，两端适用。修复前单项运行实际失败2个断言；错误SDK清单导致的另一次启动失败另行保留，不算RED。

同时修正旧测试契约：直接 AV 测试明确 .mp4；受控 decoder mock 声明显式硬件证据；managed 路由测试区分已实现机制与不可用机制；初始硬件错误采用当前 decoder.unavailable；异步状态采用有界条件等待。没有把真实硬件测试替换成 mock，也没有扩大 skip 条件。

资源 EOF/lifecycle 计数修正为进入 completed 的状态转移，完整 onState 快照仍全部计数；回归覆盖连续重复快照、重播和新会话。原生资源测试此前把每个 completed 快照误当作额外完成事件。新的计数回归先失败3个断言再通过。

## 统一验收

最终实现修订 `c2a16196891f`；生产范围哈希从 `9f19de495e72ba8fb7ec3a2f352b04f3db16a14f91e07828db05b1b44a920134` 变为 `69f6e5fc191dc55021a1f96b8a2398f8441eee84deeca9ca57521e1819053b60`，唯一生产文件差异是上述提前约束校验。早期性能/ABR采集仍绑定原快照，不改写为最终修订的性能准入。基础矩阵复用未变的Dart、Python工具、生成接口、依赖及产物检查；共享Swift修改重建两端并扩大到所有相关host Load、恢复、命令顺序、投屏、HLS/DASH、RTMP和音频资源测试。

| 检查 | 实际结果 | 覆盖边界 |
|---|---|---|
| 基础完整矩阵 | 退出0；Dart/Flutter 2,331通过；Python633项中631通过、2跳过 | 可选CGL参考、隔离目录缺历史R19采集各1跳过；不是当前原生硬件通过 |
| 复审后 Dolby 完整工具套 | 83项中82通过、1可选CGL跳过 | `YL_RUN_DECODE_PROBE=1`显式开启真实探针；默认环境不新增开发库依赖 |
| 静态/接口/产物 | analyze、Pigeon、公开面、源映射、451个Dart文件格式无改动；HEVC56、VP9218及FFmpeg3slice/5架构/57符号/9负例检查通过 | 未执行缺失设备或远程CI |
| macOS 首轮全套 | 859项，853通过、6失败、0跳过 | 原始15个断言失败保留 |
| macOS 第一批修复回归 | 18/18通过 | 包含新增completion转移回归；原RED1项3断言保留 |
| macOS 最终受影响回归 | 298项，296通过、2失败、0跳过 | 两项旧断言要求先退役再拒绝，与提前校验冲突，另行修正和重测 |
| macOS 控制意图中间回归 | 8项，7通过、1失败 | 两项提前拒绝已通过；实际回滚测试后续AV播放使用占位URL发生失败，改用已有本地MP4 |
| macOS 控制意图最终回归 | 8项，8通过、0失败、0跳过 | 保留真正退役后构造失败的回滚测试；累计当前860/860身份有通过证据，不是一次全新全套全绿 |
| iOS 首轮全套 | 813项，772通过、40失败、1跳过 | iOS27.0模拟器；首轮失败保留 |
| iOS 最终受影响回归 | 341项，307通过、33失败、1跳过 | 7项修复全部通过、0新增失败；累计当前779通过/33失败/1跳过 |
| 来源/跳过契约补验 | migration4/4、runtime evidence8通过/1历史采集缺失跳过、源映射通过 | 现有硬件skip谓词/消息不变，来源哈希显式核对 |
| 独立复审 | 1轮综合复审发现Important1，已修复；同一reviewer定向复核最终修复，无新增阻断或deferred minor | 复审结论与运行结果分开记录 |

iOS剩余33项在真实解码准备/激活路径失败。R19与FLV附件实际记录H264硬件不可用；部分失败明确为 `decoder.unavailable`，部分XCTest只给出泛化错误，因此不能把所有私有失败原因一概判定为已查明。它们需要具备正向硬件证据的iOS设备逐项复验；没有扩大skip、换成mock或宣称像素/音频输出通过。唯一R19跳过继续严格校验原身份、Simulator条件和实际能力附件。

发布台账仅更新当前源码身份、报告引用及下一步：FEL原始素材与逐帧关联已有证据，不再重复要求提供原始FEL；后续要求完整有效映射和独立目标帧/容差。102行能力状态保持：67 implemented、34 partial、1 unreviewed；验证30 external_missing、3 failed、69 not_run、0 passed。台账有效性检查不等于发布就绪，台账与阈值结构检查均退出0，两个 `--require-ready` 均实际退出1；发布台账工具15项测试通过。

## 保留的未完成项

- P08：历史119.084ms原生ready等待根因、系统内部资源A5上界、符合协议的完整平台性能准入；候选继续默认关闭。
- P04：实际AVPlayer自动恢复升档未实现验收，公开access log只能提供线索；不以强制手动切档代替自动恢复。
- P07：完整有效DM/trim继承及适用CM/NLQ映射、真实use_previous素材、独立目标和帧生成对应/容差、物理DV输出链路。
- 其他既有发布缺口：真机/最低OS/低内存/32位/Intel等矩阵、商业DRM授权链路、外部输出与源绑定远程CI；没有用本机工具通过覆盖这些缺口。

完整日志、失败/跳过、实际XCTest身份、诊断原始哈希与脱敏内容哈希见 [证据目录](evidence/2026-10-20-remaining-engineering/README.md)。主目录保持基线干净，现有投屏、媒体拆分及P07/P08成果保留；本轮提交在 `codex/remaining-engineering`，没有合并、推送或清理该工作树。
