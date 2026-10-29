# P07 离线 DM 颜色头状态

Base: `fa696c97332fd5f4c3134640f6a046caeac23ec0`。沿用 Dolby 映射契约 Task1 与 2026-10-20 剩余工程计划 Task4；本轮仅推进原有 effective metadata 的颜色头子项。

范围：固定 libdovi 原始 RPU 探针增加可选 `--dm-color`，导出原始头部，复用 mapping ID 追踪，在解码顺序内解析完整颜色头及后续压缩记录的静态颜色继承。当前 affected/current ID 必须一致；压缩记录要求已有同 ID、同序列配置的完整颜色头。新调用无历史。不猜测缺失头、未知压缩、默认 DM 或跨 ID 语义。不执行 trim/CM、NLQ/重采样或图像映射；不升级 `effective_metadata_resolved` 或生产准入。

1. RED：解码/显示重排、压缩占位零、刷新、ID 不匹配、缺历史、配置变更、未知位及输入边界。
2. GREEN：独立有限状态解析器，探针 opt-in 输出，schema 4 trace/CLI；旧 schema 1–3 保持兼容。
3. 固定归档离线构建 Rust 探针；缓存公开 P5/FEL 全片真实盘点，保留媒体/工具/trace 哈希。压缩真实样本缺失时明确保留，不以合成序列替代。
4. 全部修改后按 consolidated-acceptance 集中测试和一次独立复审；仅重测受影响范围，其余矩阵以未变化源码/依赖边界复用既有记录。记录跳过、失败、未完成及验收清单。

不操作另一个聊天的 iOS 恢复，不使用其设备，不推送、不发布；本轮未获得新的合并请求，实施留在自有分支。
