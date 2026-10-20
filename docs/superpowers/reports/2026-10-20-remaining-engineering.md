# 当前条件下剩余工程：实施与验收记录

状态：实施中，未完成最终统一验收。基线 main `978c2c5c`，隔离分支 `codex/remaining-engineering`。保留现有投屏、媒体拆分、P07/P08 成果。本文不覆盖历史失败。

## P08 当前证据与采集修正

最新续查已包含音频锁隔离、TimeJumped 抑制、静音间隙推进、ready 通知、跨节点漂移及关闭单帧持有修复；不能以早期报告的待办重复实现。历史 119.084ms 原生未就绪内部原因仍开放，参见 2026-10-11 Thread Activity 报告。

本次修复 trace 采集器一次读取多行仅分析最后一行的问题；现在每条完整观测进入判断，64KiB 增量读取，单行上限 1MiB，截断明确失败。3 项 RED、20 项 GREEN。不是生产渲染修复。

本次 Debug 当前源码短诊断：系统增量724帧、丢弃/损坏0/0；dispose 191.142ms；disposed及disposedLater账本均0；8组弱sample/reservation均消失，自有PID退出，冻结源码/产物不变。额外诊断已开启，不作为正式Profile长播或历史119ms根因闭环。原始记录暂存 `/private/tmp/remaining-timed-short`，最终归档待完成。

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

P04 iOS 恢复升档仍开放；诊断工具成功不等于 CAP-DASH/ABR 验收通过。正式入口的新运行及统一验证结果见后续验收表。

## P07 解码帧对应

新增离线软件 HEVC 探针：保留原始 MP4 包 PTS/DTS，COPY_OPAQUE 传递包编号；独立 FFmpeg HEVC parser 从参数集/切片状态计算 POC，再随包穿过 B 帧重排和 EOF 排空。逐帧关联 BL、EL、原始 RPU 哈希，输出 active planar YUV 像素字节 SHA-256、几何、格式和图像类型。截断、缺帧、重复、错包/PTS/POC、非单图像输入明确拒绝；不将呈现序号冒充 POC。软件解码与 parser 属于同一 FFmpeg 实现，不是独立目标生成器。

公开 FEL 全片实测2,908对：BL3840×2160、EL1920×1080、yuv420p10le；2,114个包呈现顺序发生重排，全部 BL/EL PTS/POC及原始RPU关联通过。官方Sol Levante P5全片6,314帧也通过包/PTS/POC关联，无EL所以 `decoded_layer_pairing_verified=false`。素材哈希分别为 `419fc183988cb57b0cac2907a01d9f43b1a5ec34012b4c0655574d77678ee4fa`、`87fe0115f3002a621d2380a9f91852ef91a15854a446efe26de8744f77ef5346`。

新增 `stream_inventory.py --mapping`：按解码顺序解析显式 `vdr_rpu_id` / `prev_vdr_rpu_id`，绑定实际被引用的系数记录及来源包；同ID重定义仅覆盖该ID，未知ID、新epoch无历史或先按显示顺序排列的输入均拒绝。默认既有输出兼容；扩展模式schema3。FEL实测全部2,908条映射引用可解析，但该素材没有use_previous样本；复用/重定义仅由合成测试覆盖，不能写成真实use_previous像素验证。

`effective_metadata_resolved=false` 保留。以上不完成跨帧DM/trim的全部有效状态、完整适用CM/NLQ目标映射，也不证明独立参考、Dolby目标像素或原生DV信号。官方Sparks独立参考/帧生成对应未新增可核验证据，沿用既有未完成项。详见 [解码工具协议](../../../tool/dolby_reference/DECODED_ALIGNMENT.md)。

## 统一验收

最终矩阵、独立复审与证据归档进行中。不会把默认关闭的候选启用，或将剩余失败/外部缺口改成passed。
