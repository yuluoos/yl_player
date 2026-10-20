# P08 续作工程证据

基线 `86143754`；TVS 实现 `b961497`。这是可审核的工程采集与本机验证，正式性能基线、物理输出、跨设备发布均未准入。最终命令、计数与日志哈希见 `validation.json`，单次复审见 `review.md`。

## 已实际采集

| 测量 | 尝试 | p50 / p95（µs） | 边界 |
| --- | --- | --- | --- |
| 公开首帧 | 3/3 | 30,888 / 491,837 | Load 前启动，Session 首帧事件接收 |
| seek 目标附近状态 | 3/3 | 681 / 997 | public state，非出图 |
| seek 连续状态窗口 | 3/3 | 1,407,824 / 1,423,612 | 1 秒进度窗口，倒退/停顿/采样空隙重置 |
| compositor 首个编号帧 | 3/3 | 94,257 / 393,407 | 本进程窗口像素；非物理 scanout |
| compositor seek 目标帧 | 3/3 | 42,281 / 42,324 | 目标 5 秒附近编号帧 |
| compositor seek 稳定窗口 | 3/3 | 1,046,663 / 1,047,244 | 连续 1 秒编号帧窗口 |

压力三轮清理与资源采集完整：实际 playing CPU 单核百分比 p50/p95 8.36%/9.19%；RSS/physical footprint/释放后值全部保留在原始 run/resources 中。media ledger 未观察到保持 null。compositor 三轮另验证自有窗口隐藏一秒后恢复出图。两项 collector 均 sourceUnchanged=true，complete=true。采样未控制 OS 缓存、其他应用负载或物理输出资格；期间也有基础回归进程运行，因此这些值仅为工程 smoke，不能作优化收益或冻结预算。

`p08-*-postreview-*.json.gz` 为最终复审后输入/观测；较早 `stress-v3`、`compositor-v2`、`compositor-fullylive` 为此前成功试验，`compositor-first/live/visible/mainactor` 保留黑帧与崩溃失败。不能挑选旧 run 的较低时延代替最终结果。`archive.json` 逐个绑定压缩文件和解压内容的哈希、字节数。result 文件包含本机原日志的哈希，原日志及生成 dylib/视频保留于本机 `/private/tmp`，不上传带 VM 服务地址的原始日志。采集器本身不保存其他应用或窗口截图。

`resolver-macos.json`：真实本地 HTTP 下载、JS VM、公开 Player 播放交接与停止，7/7；分段单位µs，debug，不是呈现基线。
`consumers.json` 和 `consumer-receipts.json.gz`：五格真实消费者构建通过，macOS 显式 opt-in lipo 兼容，默认 SDK 缺陷仍未改写。
`iphone-install-blocked.json`：resolver 示例签名构建成功，但新增安装被免费开发者配额拒绝；未移除已有应用，未计运行通过。

## 判断与限制

- 运行中的数据仅保留固定标签、数值、源身份和摘要，不记录 URL、许可证或脚本内容。受控 POST 不能证明授权 DRM 内容可播放。
- package core 的测试依赖仓库相对 fixture 路径；最初包目录执行导致的15项路径失败保留，根目录重跑通过。resolver native-assets 测试则必须在其包目录执行；example 测试在各自 example 目录执行。不是删改断言规避失败。
- TVS 取证使用其实际 package_config 指向的 player checkout；若指向其他工作树、运行中输入变化、收据缺失或二进制不可读，collector 均失败。
- 采用显式宿主兼容解决当前消费者构建，代价是默认 Flutter/Xcode 组合仍需上游修复或发布口径认可。只做本地提交整合，没有推送、标签、发布或远程 CI。
- 没有延期 Minor；未执行的物理/最低OS/授权格见 P08 报告专表。历史同 native 生产实现的完整原生与长播结果仅按原范围保留，没有重新命名为本次执行。


`iphone-player-native-transport.json`：iPhone16/iOS27，已有 player 示例原位更新后，通过1项公开播放集成用例（计划3试次）。初始 SDK x86_64 iproxy 启动失败保存在 `iphone-player-result.json.gz`；改用已安装 arm64 iproxy、原始 VM 授权路径和官方 existing-app 驱动后成功。只绑定本次应用服务、退出回收代理，没有共享 SDK 变更。未捕获逐次 stdout 指标，perAttemptMetrics=null；仅计用例实际通过，不能当作性能数据或物理输出验证。协议来源仍是该次构建的输入清单。


`tvs-source-bound-result.json.gz`：最终实际业务回归通过，6次切台，第一帧 future 观察的业务耗时分别为 3,714,662 / 2,705,655 / 2,728,010 / 2,057,343 / 2,698,892 / 2,349,808µs；真实 RTMP、JavaScript、切模式、重连耗尽/恢复、刷新及停止均执行，源身份结束重算匹配、宿主二进制哈希已取证。为避开并行 P07 合并，运行时用临时 dependency override 指向 P08 工作树；结束后已恢复 TVS 原依赖配置，TVS 提交 b961497 已快进至其 main。
