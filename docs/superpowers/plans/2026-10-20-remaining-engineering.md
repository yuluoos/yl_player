# 当前条件下剩余工程功能连续实施

Goal: 按用户批准顺序完成可执行工程，保留投屏、媒体拆分、P07/P08 成果和外部缺口。
Architecture: 沿用既有 timed presentation、资源预算、Apple DASH 与 FEL 双层管线；先核对最新证据，再做可复现缺陷的最小修复及离线诊断补齐。
Tech Stack: Swift/CoreMedia/AVFoundation、Dart/Flutter、Python、Rust/libdovi、FFmpeg。
Spec: 2026-10-10-macos-timed-presentation-design.md、2026-09-26-dolby-mapping-contract.md；P04/P08 既有计划与最新续查报告。
Base: main 978c2c5c3872d5570e3bd1a01f1a3d2e80d08f44。

## Global constraints

默认关闭的候选不自动启用；50ms/3 帧、100ms 时钟新鲜度、零系统丢帧与 3s 释放门限不放宽。历史失败不删除，不重复已完成修复。独立 Dolby 目标/容差、商业 DRM、最低 OS/缺少硬件与物理输出不能伪造。以集中验收策略执行：定向 RED/GREEN，最后统一矩阵和一次独立复审；无实现子代理。当前主目录不修改，独立工作树实施。

## Review focus

1. 系统 trace 是否覆盖同次完整 ready 事件，轮询是否丢失中间行；诊断不能代替生产验收。
2. 资源所有者、退役/晚回调/跨代释放；应用预算不等于系统内存上界。
3. ABR 估算与恢复升档的真实请求路径，caps/fixed/兼容性和取消不得回归。
4. FEL 解码顺序/显示顺序、PTS/POC、RPU 继承与缺失/重复/错位输入必须拒绝；不能用 packet 计数冒充像素合格。
5. 新报告与 source identity/ledger 一致，历史通过/失败/跳过及未验证设备保持可追溯。

## Task 1: P08 timed presentation

读取最新 Thread Activity 续查及当前实现；已有音频锁隔离、退出检查器隔离、主队列单帧释放等不重做。检查逐次事件采集完整性，若存在具体问题先写失败行为测试、最小修复，跑 playback_benchmark 定向测试。现有产物不可用则记录并以当前代码构建；只有具备明确采集假设才新跑原生诊断。没有同次因果证据不猜生产补丁。
Interfaces: run_timed_video_trace.py 的逐行观测、完整事件与 trace 收据；默认协议保持兼容。
Expected: 事件不漏、不提前截断；实际诊断结论与覆盖范围一致。

## Task 2: P08 resource ownership

核对音频/视频/下游所有者与最新 A5/R3；针对能改变结论的所有权缺口补充可核查约束及测试，真实释放/迟到回调/持续播放定向检查。不能从有限 heap 平台期推导普遍上界；系统不可证明部分继续不准入。
Interfaces: 资源预算、输出退役、诊断所有者清单；不增加经验 reset。
Expected: 可控资源的边界可验证，未知资源明确保留。

## Task 3: P04 iOS ABR recovery

从既有 40/80s 失败归档、DASH 策略和估算生产路径定位不升档原因；最小受控复现先 RED 后修复，检查 auto/caps/fixed、取消及兼容性。具备设备时执行自有弱网恢复，设备缺失则保留实际证据边界。
Interfaces: DASH throughput measurement/selection；不改变 PD02 质量兼容规则。
Expected: 可恢复估计不被客户端空闲时间污染；真实公共输出按实际运行判定。

## Task 4: P07 decoded correspondence

检查 BL/EL 解码及 RPU 继承已有边界，补齐可在本地执行的哈希绑定解码对应工具/测试。先写 B-frame 重排、丢帧、重复、错配、继承不适用输入失败测试，再实现有限输入的逐帧对应；用已缓存公开 FEL/P5 素材验证，记录工具身份与限制。
Interfaces: stream_inventory packet identity → decoded frame identity；不宣称独立参考或完整 CM/trim/NLQ 像素合格。
Expected: 实际解码证据可复核，未知/不支持情况明确拒绝。

## Task 5: consolidated acceptance

冻结候选修订、运行基础全套及受影响原生/工具/消费者检查；一次独立综合复审，修复阻断项后只重测影响范围。更新报告、未完成项、验证记录和 release ledger；不得把工具通过写成全部平台准入。
Expected: 所有可执行改动验证完成，环境/外部资源及未证根因逐项保留。
