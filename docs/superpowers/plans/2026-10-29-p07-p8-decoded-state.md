# P07 P8 压缩状态的实际解码链路

Base `83554d908f6d64a49bdc7906e108e2dc3be3ab0a`。延续 P07 Task1 来源与帧绑定前置验证，采用 consolidated-acceptance。

1. 为 decoded_alignment 增加 P8 单层输入；拒绝混合 profile 和携带 EL 的 P8，保留 P5/P7 原有行为与两个输出 schema。
2. 用本机 libx265 生成含 B 帧和闭合 GOP 的 12 帧 10-bit 视频；测试专用 mux 夹具按原始包顺序附加固定 libdovi 生成的完整/压缩/重置 RPU，保留原始 PTS/DTS。以独立不带 RPU 的软件解码像素哈希作来源对照，不作 Dolby 画质目标。
3. 实际 MP4 → ffprobe → 原始 RPU → libdovi → mapping/颜色/CM 状态 → HEVC 解码与 POC → 呈现顺序 trace，验证继承、动态块过期、重置、重排及孤立压缩记录拒绝。
4. 必要定向 RED/GREEN 后一次 P07 全套与台账结构检查、独立综合复审；归档输入/工具哈希与结果。生产代码未变部分复用对应既有记录。

不扩展完整 Dolby 映射能力。真实压缩/use_previous 片源、压缩 CM4 动态块解析限制、缺头/默认 DM/跨 ID、独立目标生成合同及容差、物理 DV 和其他设备/授权缺口继续保留。另一聊天的 iOS 恢复排除；不提交、不合并、不推送、不发布。
