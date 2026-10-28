# iOS public-host 真机清晰度矩阵实施与验收

基线7c4cf933；继续用户已授权的未完成项。沿用系统排障、测试驱动、集中验收；当前工作树直接实施，不发布。

目标：补齐原生typed public host在真实120秒素材下初始自动、320宽度上限、清除上限、固定320低档、恢复自动的媒体/策略观测。此轮不接入生产自动恢复，不把普通切换矩阵当作恢复竞争、物理屏幕或音画连续性验收。

实现选择：复用现有受限地址、制品身份、240秒采集和140秒原生期限；显式--public-policy-cycle只能用于managed DASH、120秒、无诊断恢复。四个命令按8/24/50/70秒发起，通过YlApplePlayerHost公开typed方法；采样来自host当前状态、accepted constraints、AVPlayer及实际纹理帧。每条命令单独记录开始/结束、item变化和session身份。新增失败关闭的采集校验，不因到片尾而忽略缺失阶段或无新帧。

- [x] Python验证器先红后绿：缺阶段、命令失败、session变化、策略失守、缺新帧及恢复自动后无高档必须失败。
- [x] 原生接入public host周期，canonical和iOS/macOS镜像同步；定向构建。
- [x] 同一制品在原冻结配置及独立零延迟诊断配置各采集一轮；不改原配置/恢复门槛，失败保留。
- [x] 最终受影响原生/工具矩阵、一次独立复审、原始证据与完整xcresult归档、更新台账并本地提交。

保留其余未完成项：原配置稳定自动恢复、旧候选与public host竞争、凭据竞争、新帧空档、物理路由与音画/字幕、多设备最低系统、DRM/Dolby授权。旧终末停顿不恢复待办。

新增已确认根因：public host加载在首请求前返回policy.unsupported，prepareDash的managed HTTP预检不识别IPv4字面量的NSAllowsLocalNetworking授权。Apple文档确认该配置覆盖IPv4/IPv6。先保留真机失败和原生产判断的单测红灯，再按文档修正字面地址识别；显式域名/代理/固定证书限制仍优先，既有ATS配置不改。因涉及共享media core，最终扩大到NetworkRequestPolicy原生矩阵和独立media-core消费者构建/契约检查。

最终回归补充：原生路由暂停16秒后被延迟item-ready回调覆盖为ready。真实媒体+KVO顺序回归先红，保留已确认paused的最小修复后验证初始ready/暂停不动/显式续播；最终扩大到共享AvPlayer受影响矩阵和两轮同制品真机媒体。
