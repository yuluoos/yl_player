# P07 P8 压缩状态与实际解码链路（2026-10-29）

基线 `83554d908f6d64a49bdc7906e108e2dc3be3ab0a`；分支 `codex/p07-p8-decoded-state`。本轮仅修改离线工具、测试和记录；未提交/合并、未推送、未发布。

## 已实现与定向验证

`decoded_alignment` 接受同质 P8 单层输入，继续拒绝混合 profile、未知 profile、P5/P8 携带 EL 和缺 EL 的 P7；旧 schema 1 和元数据 schema 2 均保留。P8 `--metadata` 经过实际 MP4/ffprobe/libdovi/HEVC 解码链路，把颜色、mapping 和已知 CM 块的来源绑定到实际帧的 PTS/POC/像素哈希。

测试专用 `mux_rpu_fixture.c` 以固定 libdovi 生成的完整/压缩/重置/压缩四条 RPU 循环附加到生成的 12 帧 10-bit 视频原始包；不是生产 Dolby 封装器。3 项实际集成测试和 8 项来源/边界测试通过。原始 RED 准确停在旧 P5/P7 profile 门禁，修复后 GREEN 通过。

本机结果：12 帧、7 个包发生显示重排、6 个压缩/previous_mapping RPU、6 个继承静态块实例，2 帧的继承来源在呈现时间上晚于本帧。验证颜色/mapping 来源、静态 L6/L254 继承、动态块逐包过期、完整记录重置，以及两段闭合 GOP 的 POC 重置。对照原始无 RPU 视频，逐包 PTS/DTS、基础层字节和全部解码帧完全一致。孤立压缩记录拒绝且不输出 trace，RPU 数量不足/过多拒绝。生成内容不是独立 Dolby 映射参考或真实压缩片源。

## 集中验收

本轮范围的集中验收完成：

| 检查 | 结果 |
| --- | --- |
| P07 全套（启用宿主解码、P8 集成、NumPy 2.3.5） | 105 项：104 通过、1 项既有 CGL 未启用跳过，66.074 秒 |
| 台账测试 | 15 项通过 |
| 发布/性能结构检查 | 各退出 0，发布 sourceMatches=true；完整资格仍未就绪 |
| 发布/性能 require-ready | 各退出 1，按预期阻止完整发布资格 |
| 候选与影响边界 | 64 个 P07 文件身份匹配，播放器/依赖/CI 空 diff，git diff --check 通过 |
| 独立综合复审 | fresh-context 审查者无可操作发现；独立 ffmpeg → rawvideo 解码原片的 12 帧哈希全部匹配 trace |

证据目录保存 RED/GREEN、实际 trace、工具/输入身份、逐项命令退出值和复审原文摘要。独立复审没有改变任何文件，没有启动设备或其他聊天的工作。通过范围为生成元数据的离线来源链路，不是完整 P07 或设备验收。

复用上一轮同源码的固定 Rust inspector 4 项测试、真实 P5 6314 帧/FEL 2908 对全片解析与解码证据。当前只扩展 profile 门禁，保留 P5/P7 规则；解析器、颜色/CM/mapping 状态模块、HEVC C 解码探针及 Rust 夹具均与上一轮一致。本轮实际重新构建 C 解码探针和测试 mux，运行新 P8 生成视频。播放器、依赖与 CI 空 diff；不重复设备矩阵或另一个聊天的 iOS 工作。

## 继续保留

真实压缩/use_previous 视频来源、压缩 CM4 动态块/L254 固定库限制、跨 ID/缺序列头/默认 DM、未知保留扩展、完整 CM/trim/NLQ/重采样/目标映射、独立 FEL 目标生成合同及冻结容差、物理 DV 均未完成。`effective_metadata_resolved=false`，`mapping_quality`/`native_dv_signal=external_missing`，CAP-DV-MAP/OUT 不提升。

P02/P03/P05 的设备、最低 OS、硬件、热稳态和业务来源；P06 DRM 授权；P08 READY 同次因果证据及系统 A5 上界继续保留。P04 iOS 恢复由另一聊天处理，本轮不操作其源码、工作树、设备和进程。

台账仅补本报告引用，102 行 implementation/verification/acceptance/nextAction 保持原样（67 implemented、34 partial、1 unreviewed；30 external_missing、3 failed、69 not_run、0 passed）。生产源哈希保持 `b4651f1fd23bf40cbc2384b2a0f39c0f0f90b0f736ca918b71aa25a895972eb5`。

[原始验收证据](evidence/2026-10-29-p07-p8-decoded-state/)。旧失败、跳过与先前验收记录不改写；原始生成媒体和可执行文件仅保留在本机 `/private/tmp/yl-p07-p8-state/`，仓库保存身份与压缩 trace。
