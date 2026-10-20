# P03 工程收尾续做

继承已批准的 2026-10-14-p03-completion-design.md 和对应实施计划；不新增编解码承诺。
基线 db769ffd（包含本会话 P02 的 AVPlayer 片尾 seek 修复），独立分支
codex/p03-engineering-completion。主线投屏开发与 P04 工作树不在本轮修改范围。

## Task 1: 核对现有实现和公开诊断

逐项对应既有 P03 八项任务。格式、软件候选、预算和严格策略已有实现，避免重复。
修正 Vorbis 公共安全消息仍宣称零 CodecDelay 的遗漏；运行既有诊断与实际音频回归。
短测量和未确认热稳定性不能打开生产软件档位。AVPlayer source-pull 不是硬件消费
计数；保留原严格门禁，不用 currentTime 或另一播放器替换真实消费证据。

## Task 2: iPhone 同构建采集工程

既有公开 Flutter 采集器的 iOS 分支仅支持 simulator。增加显式物理设备目标，
通过 Flutter 的调试启动保持 JIT/debugger 正常，通过仅验收构建可读取的一次性计划文件传递输入；
使用 appDataContainer 复制本轮 UUID 下的结果，不能将设备路径当宿主路径读取。
维持安装字节/加载镜像/媒体/会话/框架完成与清理门禁；失败复制、超时、过期或
错误身份不能算通过。模拟器与 macOS 路径保持原行为。新增测试先 RED 后 GREEN。

## Task 3: 集中验证

执行解码/格式工具完整套件、受影响原生与 Dart 测试、静态检查；原生构建串行。
iPhone 运行同构建公开控制与有条件 AV1/Main10 实际硬件验证，保留成功与失败。
没有硬件消费观测或外部资源的格仍开放；不更改 40 项必需格式分母或容差。

## Task 4: 最终复审和交付

一次独立整体复审，修复重要发现；记录源码/制品身份、原始日志和覆盖矩阵，
更新工程完成与资格/物理验收两类状态，本地提交，不 push 或合入主线。

## Review Focus

Physical-device vs simulator identity; prebuilt bundle unchanged by launch;
copy failures and stale status cannot pass; exact owned process cleanup;
AVPlayer source-pull is never reported as hardware consumption; no synthetic
software measurements enable production; source credentials remain redacted.
