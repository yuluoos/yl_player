# 当前可执行剩余工作与集中验收

> 执行方式：superpowers:executing-plans；consolidated-acceptance。用户已授权连续实施、最后统一测试验收和更新发布台账。无需逐任务确认。

Goal: 在 a31b624af8f828a90e83c8050d588b9683404c2b 上继续现有 P02–P08，完成当前可执行工作，准确保留硬件、授权、参考与未证根因。
Architecture: 沿用现有播放器、系统 ABR 和发布检查器；只修复可复现问题，不通过强制切档、扩大跳过或修改阈值制造通过。
Tech Stack: Flutter/Dart、Swift/AVFoundation、Kotlin、Python。
Spec: ../specs/2026-09-20-playback-expansion-requirements.md；../specs/2026-09-26-dolby-mapping-contract.md；2026-10-20-remaining-engineering.md。

## Global constraints

- Android24、iOS15、macOS12下限不变；默认关闭候选保持关闭。
- 保留现有投屏、媒体拆分、错误诊断、HEVC、FFmpeg最低系统和Android内存压力成果。
- 50ms/3帧、100ms时钟新鲜度、零系统丢帧、3s释放门限不放宽。
- 缺设备/授权/独立参考的项目单列，不能将内部未知根因归成设备缺失。
- 不推送、不发布；隔离工作树实施。单项定向验证，最终一次综合矩阵和独立复审。

## Review focus

1. ABR观察必须来自实际生产路径；诊断成功和自动恢复成功分别记录。
2. 清理异常、超时、未发现宿主进程及迟到结果不能产生成功收据。
3. 最新源码与台账身份一致；原始失败/跳过、已有阶段成果不能被覆写。
4. 缺物理输出、授权和参考不以mock/模拟器/编译替代。
5. 本轮修复的定向证据和最终统一验证范围可对应到具体快照。

## Task 1: 当前范围与ABR续查

- [x] 核对P02–P08最新记录和当前设备；记录每项解除条件。
- [x] 核对DASH→HLS/代理路径和实际弱网收据；构建当前原生宿主，执行既有ABR诊断。
- [x] 对可证缺陷先加失败测试，再最小修复并定向验证；无法建立因果的系统策略保留开放。
Files: tool/playback_network/abr_accesslog.py、test_abr_accesslog.py及有证据涉及的原生文件。
Interfaces: summarize/run 的实际观察、进程所有权及失败收据；保留 capabilityAccepted=false。
Expected: 实际恢复与未恢复均可准确追溯；无猜测性策略变更。

## Task 2: 剩余本机工程及最新提交一致性

- [x] 核对P07参考门槛、P08资源/ready已有证据，不重做已完成诊断。
- [x] 检查最新错误诊断、HEVC、FFmpeg和Android内存压力修订与测试/制品的一致性。
- [x] 修复当前构建/定向验证发现的可复现缺陷；保留外部资格条件。
Interfaces: 现有公开协议、原生镜像及产物校验不变。
Expected: 本机可执行缺口有实际结果；不可执行项具有具体原因。

## Task 3: 集中测试、复审及发布台账

- [x] 运行foundation完整矩阵、Apple原生两端、Android JVM、P08补充、可用消费者/工具检查；记录真实失败及跳过。
- [x] 执行一次独立综合复审；修复后只重测相关范围。
- [x] 写入本轮报告、证据哈希、任务检查点，更新inventory源码快照及逐项nextAction；不提升未完整验收的组。
- [x] 验证台账sourceMatches=true；分别运行两个require-ready并保留尚未就绪的结果。
Files: docs/superpowers/reports/2026-10-26-remaining-acceptance.md、其evidence目录、tool/release_readiness/inventory.json。
Expected: 台账有效且匹配当前源码；releaseReady仅按真实完整验收计算。
