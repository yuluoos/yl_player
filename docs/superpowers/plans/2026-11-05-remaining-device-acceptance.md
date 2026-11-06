# 当前设备剩余功能与集中验收执行计划

> 使用 executing-plans 顺序实施；consolidated-acceptance 调整为必要定向检查后一次集中验证和综合复审。

**Goal:** 完成当前设备/资源允许的剩余工程和验收，准确保留外部缺口。
**Architecture:** 沿用现有播放器、冻结制品采集器和组级台账，不新增播放器路线或修改已批准阈值。
**Tech Stack:** Flutter/Dart、Swift/Xcode、Kotlin/Android、Python 验收工具。
**Spec:** ../specs/2026-09-20-playback-expansion-requirements.md（v2.2）

## 约束

- 基线 13f45f7e，初始工作区干净；用户已批准执行及集中验收，无需再次确认计划。
- 不做假设性兜底，不重复无变化的有效验证；失败保留，仅补验受影响部分。
- Android API24、iOS15、macOS12 产品下限不变；不接商业 SDK、不降画质、不放宽门限。
- 当前有 M1/macOS27.0.1、iPhone16、Android API36 模拟器。最低OS/Intel/32位/物理Android不可用。
- 不触碰另一任务已启动的 iPhone Duo 模拟器；本轮设备和构建串行。
- 不推送、合并、发布；不删除其他任务构建或证据。

## Task 1：同构建格式矩阵

- [x] 准备一个当前源码、签名且 YL_BOUND_AV 启用的 iPhone 制品；先定向采集验证启动/传输，再冻结完整矩阵。
- [x] 准备 Android API36 独占只读模拟器及当前 APK；保留硬件不可用行，不把模拟器当真机。
- [x] 发现实际缺陷时先记录失败，再最小修复和定向验证；完整矩阵在最终候选上执行。
- Files: tool/media_matrix/run_bound_flutter_matrix.py、run_bound_flutter_apple.py、run_bound_flutter_android.py、bound_device.py 及对应测试；仅证据需要时修改。
- Interface: 既有 plan/status/rows、40 required + 4 diagnostic、源码/制品身份不变。

## Task 2：P08 可执行工程

- [x] 复用已通过 M1 AV1 和长播证据。READY 历史事件仅在有可检验因果假设时采集，不无变化重复长播。
- [x] 对 A5 系统资源上界沿用不准入决策；公开接口不能证明的系统内部边界明确保留，不以账本0替代。
- [x] 梳理现有消费者、基线和可用资源的实际阻塞；完成有证据支持的工具/工程修复。
- Files: tool/playback_benchmark、tool/check_consumers.sh、相关报告和发布台账。

## Task 3：集中验收及归档

- [x] 冻结最终源码和制品；运行当前可用 iPhone/Android 完整格式矩阵。
- [x] 执行适用 foundation、原生/集成、消费者、生成/产物检查；复用身份不变证据，所有失败/跳过单列。
- [x] 运行性能及发布结构/require-ready，缺条件继续拒绝。
- [x] 一次独立综合复审；局部问题仅定向修复复验。
- [x] 写报告、更新台账证据及后续动作；不把部分通过改成整组通过。

## Review Focus

实际运行身份、失败分母、设备所有权和停止回执、未变证据复用、完整资格与局部通过的区分。

## 执行结论与偏差

以上勾选表示计划内动作已执行或明确记录阻塞，并不表示全部验收通过。iOS 39/40、Android 36/40，完整分母各 44 格；外部及工程证据缺口见最终报告。

早期功能采集曾与本轮其他构建/采集并发，偏离原串行安排；最终失败格补验串行执行，未据并发数据作性能结论。原只读 AVD 存储不足，改用本轮专属临时 AVD（12 GiB 数据盘），未修改原 AVD。实际失败触发四批最小修复及定向复验，未重复已通过且身份不变的检查。
