# 独立复核记录及后续验证范围

一次只读复核由 `p03_avplayer_audio_review` 完成。本文件是主执行者对已收到复核结果的归档摘要，不是新一轮复核。

- Critical：无。
- Important：无确认项。
- Minor：BOUND_AV.md 的“epoch/range/frame consistency”可能暗示取数区间时长与输出帧数一致。已改为“epoch and range/frame validity”，并说明两者独立保留；没有延期 Minor。
- 审阅结论：实现方向可继续，最终运行和构建隔离结果应在提交前补齐。

审阅者未作判定的内容：最终 MP4 释放实跑；普通 Debug/Release 排除与最终回归；硬件播放头/物理输出；远程、DRM、多音轨、变速及任意格式；其他 P03 格式、持续热、长播放和弱网 ABR。前三者中可执行的工程检查已完成并保留原始结果，物理/硬件消费及未扩展内容仍开放。

复核之后，实际运行继续揭示 observer 持有 host 阻止 finalize、反复暂停导致 tap PCM 空洞、报告线程 try-lock 导致丢块，以及新时间映射误影响 fallback。分别修复为释放已 disposed host 的强引用、连续 pre-effects 取数、预分配不可变槽位原子发布，以及仅在 AVPlayer 上映射/去重/额外暂停。**这部分最终 diff 未经过第二次独立复核**。主执行者执行原生45、Flutter96、Python61、两端 MP4 与四项实际负例、macOS六控制、构建隔离和原始重放作为验证，不将它们描述为独立代码审阅。
