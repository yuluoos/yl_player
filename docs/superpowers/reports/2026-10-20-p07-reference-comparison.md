# P07 参考身份、帧定位与数值比较（2026-10-20）

基线 `175145fc`，工作分支 `codex/p07-engineering`。本轮完成参考身份核验、精确时间轴定位和离线 RGB 比较工具，并统一执行相关回归。**完整 P07 仍未完成**：官方 HDR10 目标的生成/跨序列帧对应契约、FEL 同源独立目标及冻结容差、完整适用 CM/trim/NLQ 映射和实际 DV 信号链路仍缺。本轮未改动生产渲染、投屏、媒体拆分和支持矩阵。收尾时主目录已由并行 P08 工作推进至 `86143754` 且干净；本轮仍在 P07 隔离分支验证，不冒充该新主目录的联合验收。

## 核实的独立参考与帧对应

已下载的 Sparks 第 1000 帧 EXR 与 Netflix 原始 VDM [官方 checksum 清单](https://s3.amazonaws.com/download.opencontent.netflix.com/TechblogAssets/Sparks/sparks_vdm_hdr_p3d65_pq_20161026_01_4096x2160/vdm/hdr/p3d65_pq/20161026_01/4096x2160/checksum.txt)中的文件名、53,119,100 字节及 MD5 `400dbd685d0a3cf1c4cc05b06596c520` 全部一致。本地原图 SHA-256 为 `f34e1c18693c3bb6d218936b1957bf392a0f2888beda81c7dbf8a631aec75285`；清单 SHA-256 为 `b5cdc1d6274fe5ae2696e04c00942f7024d6c2c9e36d7cdf19854acd6ccab493`。这建立了与发布者 VDM 资产的字节身份；MD5 用于旧发布清单的识别，不当作安全签名。

官方[制作流程](https://netflixtechblog.com/engineers-making-movies-aka-open-source-test-content-f21363ea3781)和[资产说明](https://s3.amazonaws.com/download.opencontent.netflix.com/TechblogAssets/README.txt)将 VDM 定义为 P3-D65 PQ、output-referred，与 ACES-linear GAM/NAM 区分。因此不能用 EXR 扩展名或解码器默认 linear 标签替代发布者色彩描述。

对序列 0、1、960、999、1001、13776 获取了有证书验证的 HTTPS Range 头部（HTTP 206），第 1000 帧使用此前完整原文件。它们声明 60000/1001 fps、4096×2160；**960 与 1000 的原始 timeCode 均为 `0016000000000000`**。此时码不是唯一帧标识，不能据它自动配对 EXR、TIFF 和 XML，也没有据此推断具体编码原因。

有理数定位的实际结果：

| 时间轴 | 总帧数 / shot 数 | 显式帧号 1000 的位置（从 0 开始） | 精确时间 |
|---|---|---|---|
| Sparks XML | 13777 / 39 | shot 2，区间 [917,1484)，段内 83，明确 L2 target ID 1/27/48 | 1001/60 秒 |
| Sol Levante XML | 6314 / 72 | shot 12，段内 33，明确 L2 target ID 1 | 125/3 秒 |

这些结果证明 XML 内的算术位置，**尚不证明同编号 HDR10 TIFF 的输入帧、偏移、grade、目标生成版本或 trim 继承**。Sparks 与社区 FEL 测试片也不是同一输入，不能互为输入/目标。完整观察记录见 [frame-binding-observation.json](evidence/2026-10-20-p07-reference-comparison/frame-binding-observation.json) 和 [Range 收据](evidence/2026-10-20-p07-reference-comparison/range-observations.json)。原媒体与完整清单留在忽略的研究缓存，没有提交大型媒体。

## 完成的工程功能

- `reference_timeline.py`：有界解析单 Output/Track MDF 2.0.5；验证连续 shot、目标引用和精确整数/有理数 PTS；读取有界 EXR 头，原始时码仅展示；绑定官方清单和原文件身份。拒绝重叠、间隙、歧义、实体、截断及不支持的结构，不冒充生产解码器的错误判定。
- `pixel_compare.py`：冻结合同 SHA-256，校验 source、文件哈希、精确帧号/PTS、有效元数据身份、目标参数、色彩域和显示代次；比较 RGB float32 绝对 nit，统计全图、active area、边界和色度边缘的 max/RMSE/p99/最大误差位置。拒绝非有限值、长度错配、路径逃逸、旧代次帧及过大输入，无自动归一化/裁剪排除/色域转换。
- 候选参考永远是 diagnostic，退出 3，即使数值为零也不能通过验收。reviewed 模式是操作者提供的独立审查声明，工具校验证据字节和数值，不判断证据内容真实性、实际捕获来源或冻结时间。`mapping_quality_pass` 与 `native_dv_signal_pass` 始终为 null，正式画质/物理信号仍需分别验收。
- 显示代次由采集端提供；离线比较器没有实时显示监听。有效元数据 hash 也须经采集端继承解析，不能把原 RPU signalled hash 直接冒充。研究依赖固定 NumPy 2.3.5，不新增生产依赖。

完整格式、边界、CLI 和合成可复现示例见 [REFERENCE_COMPARISON.md](../../../tool/dolby_reference/REFERENCE_COMPARISON.md)。示例是明确标注的 2×2 合成错误，不是 Dolby 参考。

## 集中验证

采用用户要求的 consolidated-acceptance：实现时有定向 RED/GREEN，全部实现后集中相关完整矩阵，最后一次独立综合复审。执行环境为当前 Apple Silicon Mac；Python 3.12 / NumPy 2.3.5，Flutter 位于 `/Users/yy2021_8689/flutter`。

| 检查 | 本次结果 | 证据 |
|---|---|---|
| 全部 dolby_reference Python 测试 | 67 项：66 通过，1 项原有 opt-in CGL 跳过；新增 NumPy 数值测试实际执行 | final-python.txt |
| 固定 inspector Rust framing | 3 通过，0 跳过 | final-rust.txt |
| Apple HDR 宿主套件 | 7 组 PASS：10-bit/HDR/SDR 策略、mailbox、sample rendering、lease/lifetime | final-hdr.txt |
| Metal FEL GPU/CPU | metadata、signed/zero residual、MMR、HDR half-float 数值及 native layer enqueue 通过 | final-metal.txt |
| 原始 P5/P7 全片重扫 | P5 6314 包、P7 2908 包；摘要（允许历史可执行文件 hash 变化）及 trace hash 与已存证据一致 | p5-regression.json / p7-regression.json |
| 候选示例 CLI | 退出 3，diagnostic，数值阈值不满足，符合预期 | example-cli.json |
| 4096×2160 合成已知误差 | 最大 2 nit、RMSE 0.0003882062460937135、p99=0，定位 [0,0,R]；diagnostic | 4k-smoke-result.json |

4K smoke 进程峰值 RSS 为 819,970,048 字节；这是一次主机工具资源观察，不是生产性能基线。HDR/Metal 存在已有 SDK 弃用等警告，完整日志保留。Metal 算术通过不替代 CGL 跳过项，也不证明原始 FEL 完整画质。没有运行移动真机、物理外屏或整仓 Dart 测试；本轮无 Dart、生产 native、共享协议或生产依赖改动。P08 历史发布状态未提升。

命令和结果见 [validation.json](evidence/2026-10-20-p07-reference-comparison/validation.json)，证据及相关源码最终字节由 SHA256SUMS 绑定。[独立复审与修复记录](evidence/2026-10-20-p07-reference-comparison/independent-review.md)已归档。复审发现的循环符号链接安全错误边界已用五个 CLI 反例先失败后修复，受影响比较器全部14项通过；其余源码/依赖/环境未变，复用上述完整矩阵。第960帧缺失的Range收据已补取并确认与原缓存一致。没有未处理的阻断发现，也没有将两轮测试相加冒充一次完整结果。

## 剩余解除条件

需要可追溯的源帧→目标帧生成契约（目标峰值/黑位/色域、版本、时空对应、有效元数据）及事先冻结的容差，才能把官方候选升级为独立 golden；FEL 还需同源重建/目标输出参考。之后按被证实的元数据子集实现完整 CM/trim/NLQ 与显示目标变化行为。原生 DV 输出另外需要明确设备→转接器→电视的真实链路及切换恢复证据。此次工具和核验可以独立使用，Task1 整体、Task2/3 完整映射和 Task4 不勾选完成。
