# P07 杜比完整映射与输出 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 延续当前会话自行执行方式；本计划不自动启动子代理。

**Goal:** 在保留既有 FEL 工作的基础上，证明并实现适用元数据到目标屏幕的完整映射，并独立验收原生 Dolby Vision 输出。

**Architecture:** 把 FEL 重建算术、动态元数据/CM 显示映射、原生 DV 信号分为独立证据链。先固定开源/系统候选及独立参考，再扩展像素管线；参考不足时保留明确缺口，不用忽略元数据或基础层播放代替目标。

**Tech Stack:** 既有 FEL/VideoToolbox/Metal 路线、Android 系统解码输出、候选开源色彩处理、独立参考图与信号证据。

**Spec:** [需求基线 v2.2](../specs/2026-09-20-playback-expansion-requirements.md)、[架构入口](2026-09-22-playback-feasibility.md)、[执行总览](2026-09-26-remaining-overview.md)。

**起点：** `5409313`；当时计划状态为未开始；2026-09-28 Task1调查进行中，尚未整体完成。此后执行前重新记录 HEAD 和工作区，不能覆盖后来改动。

## Global Constraints

- Android API 24、iOS 15、macOS 12；能力自身可限定版本，不能提高整个包部署下限。
- 使用系统 API 与开源方案，不接入商业 SDK；保留已有 Apple 音频/FEL 和 Player/Session 行为。
- managed 请求、跨域凭据过滤、取消/重试预算必须实际执行；不能执行的严格策略明确拒绝。
- buffer.bounded 不是提示；hardwareRequired 需要实际解码器证据。不得静默软解、降低固定档位或放宽 HDR/Dolby 约束。
- PD-01 已确认：下一 Period 缺固定档位时回到自动，仍受独立上限约束。PD-02/03 尚未确认，只阻塞各自依赖步骤。
- 错误保留 code/category/scope/retryable/diagnosticId；不泄漏地址、请求头、许可证、脚本任意文本或原生堆栈。
- 先测基线再冻结优化目标。模拟器、受控服务、mock 与真实设备/授权资源证据分开；跳过不计通过。

## Review Focus

- 有效但现管线未知的元数据/CM：明确不支持，不当作损坏或忽略（任务 1/2）。
- NLQ/重采样与显示映射局部通过：不能推出最终画质通过（任务 2/3）。
- 目标峰值/黑位/色域变化、外接断接：映射和输出重新评估（任务 3/4）。
- 解码/映射资源不足：不得丢 FEL 或降基础层假装成功（任务 2/3）。
- 电视出现 Dolby Vision 标识但映射有误：信号与独立画面对照分别验收（任务 4）。

---

## 范围与依赖

现有 `YlFELMetadata` 仅接受 L1/L5/L6，拒绝 creative trims；`YlFELCompositor` 并非完整显示管理。现有 FEL 算术/图像工作保留。Profile 5/7 MEL/FEL/8.x、NLQ、L1/L2/L4/L5/L6/L8 和 CM 版本是必须调查的维度，不是已经冻结的支持声明。

任务 1 应尽早推进；目前缺独立参考、误差容差和指定外接链路。P03 提供 codec/输出能力，P08 提供性能基线。动态范围自动切换依赖 PD-02；单一既定格式的映射实验不依赖该决定。禁止商业 SDK，不能声称开源候选一定足以满足完整目标。

## 文件与接口

以下 Apple 文件位于 `packages/yl_player_apple/darwin/yl_player_apple/Sources/yl_player_apple/Shared/VideoToolbox/`：
- 现有：`YlFELMetadata.swift`、`YlFELCompositor.swift`、`YlFELVideoDecoder.swift`、`YlFELPairing.swift`、`YlFELConfiguration.swift`、`YlHDRVideoPolicy.swift`、`YlVideoPipeline.swift`、`YlSampleBufferVideoRenderer.swift`。
- 现有检查：`tool/apple_fel/pairing_tests.swift`、`run_tests.sh`；HDR 既有检查位于 `tool/apple_hdr/`。
- Android：`packages/yl_player_android/android/src/main/kotlin/dev/ylplayer/yl_player_android/YlMedia3Core.kt`、`YlMedia3Configuration.kt`；公开 `packages/yl_player_platform_interface/lib/src/model/source_assessment.dart`、`capabilities.dart`、`failure.dart`。
- 新建：`docs/superpowers/specs/2026-09-26-dolby-mapping-contract.md`；`docs/superpowers/reports/2026-09-26-remaining-07-dolby.md`；`tool/dolby_reference/cases.json`。

任务 1 的输出是固定版本的参考/能力矩阵；任务 2 的输出是适用元数据和目标显示参数的精确类型/单位及失败映射。后续不得从未冻结的上游 main 分支结构直接定义公共 ABI。

### Task 1：参考、候选与完整性门槛

2026-09-28（基线e69d5dc）：[执行报告](../reports/2026-09-26-remaining-07-dolby.md)。以下已完成子项不能替代完整门槛：

- [x] 1A：冻结现有FEL/HDR/桥接源码和合成夹具hash；本机6个检查程序通过；固定候选源码版本/哈希、本机依赖预检及缺口报告。
- [x] 建立24行Profile/CM/level调查台账（三平台72个状态行），配套8项校验测试；定义独立参考与比较规则。
- [x] 1B1：固定libdovi/libplacebo三端arm64构建；本机有限测试；官方P5输入hash/首RPU盘点。不是GPU精度或最低系统运行验收。
- [ ] 1B2：补齐原始FEL及独立参考/最终容差，完成候选实际渲染精度/设备实验，满足下列全部门槛后才结束Task1。


- [ ] 冻结既有 FEL 相关源文件与原始样本哈希，跑现有算术回归确认工作基线；任何候选路径都不得先删掉现有实现。
- [ ] 核查系统/开源候选的实际版本、三端构建、适用 Profile/CM、元数据处理范围、输出精度与依赖限制；源码出现字段不等于实现完整。
- [ ] 取得可合法使用的原始动态元数据样本和独立参考输出，记录参考生成方/路径、目标显示参数、时标、码值/色域、误差度量。不能以被测 compositor 自己生成的图当独立参考。
- [x] `cases.json` 首轮调查网格每个 Profile/元数据组合分别记录：输入hash、参考hash、算法算术状态、最终画质状态、输出信号状态、缺失条件。没有参考的行保持未验证。
- [ ] 冻结误差度量/容差及比较区域（含裁剪与边界），再开始映射实现；候选不能满足时报告具体元数据/平台缺口和下一验证实验。提交可行性报告，不把未通过门槛标可行。

### Task 2：完整适用元数据与 FEL 重建

- [ ] 对已证明可行的元数据集合，先写 parser/validation 用例：截断、未知level/CM、值域溢出、时序变化、缺依赖。建立正式 ERR-09 映射，区分不支持与损坏。
- [ ] 在 contract 文档定义 NLQ/重采样/trim 等适用阶段的精确输入输出、单位、色彩域与计算精度；明确未适用与未实现的区别，不能用通用 HDR tone mapping 冒充适用处理。
- [ ] 实现经参考支持的重建阶段；每一阶段先有独立 golden vector 再修改。对 FEL pairing、reset、flush、帧重排保留原测试。
- [ ] 构造错误路径确保内存/计算限额不会引发静默丢 FEL 或改播 BL；实际失败使用安全错误和诊断 ID。
- [ ] 跑算术与完整图像对照，报告两个层次结果；按已证明子集提交，未实现元数据仍明确拒绝。

### Task 3：目标屏幕映射与三端策略

- [ ] 消费 Task 1 的参考和 Task 2 的完整图像，固定显示峰值、黑位、色域/传递函数、原生/外接目标；测试多帧动态元数据，而不只比较静态截图。
- [ ] 新增不变量和独立像素误差测试，以下为参考比较规则示例，实际 `max_error` 必须先由 Task 1 冻结：

```python
# actual/reference 为同一色彩域、同一帧和同一区域的数值数组。
assert actual.shape == reference.shape
assert np.isfinite(actual).all()
error = np.abs(actual.astype(np.float64) - reference.astype(np.float64))
assert float(error.max()) <= max_error
# np 是测试工具的 numpy；不能先把 actual 转成 reference 来消除差异。
```

- [ ] 按平台实现可行路径，保持精度、几何/裁剪、字幕合成边界；显示重建/外接变化重新计算目标参数。系统路径的内部处理未知时必须借独立参考验证，不能凭标签判定。
- [ ] 消费 P08 目标测 CPU/GPU/RSS/热状态及持续播放；性能不足时记录受限设备/组合，不以降画质达标。PD-02 未定时不新增自动 SDR/HDR/DV 转换策略。
- [ ] 提交映射实现、原始数值/参考图证据及已验证能力行。

### Task 4：原生 Dolby Vision 输出单独验收

- [ ] 固定真实链路：设备型号/OS→连接/转接器→电视型号/固件/输入模式，记录原始样本、应用构建、允许获取的信号证据和画面观察。
- [ ] 分别验证本机和外接、进入/退出全屏、热插拔、后台恢复、格式变化；普通 HDR/EDR 或电视显示 DV 标志均不单独构成完整成功。
- [ ] 记录 `mapping_quality_pass` 与 `native_dv_signal_pass` 两个独立结果；前者必须 Task 3 的参考证据，后者必须实际输出链路证据。
- [ ] 缺链路保持 CAP-DV-OUT 外部条件缺失；缺参考保持 CAP-DV-MAP 未验证。完整目标无法达成时明确差距，不通过换名字宣称完成。
- [ ] 提交三端按链路分行的报告，交 P08 共同验收。

## 交付与检查

- [ ] 按任务提交可独立验收的改动；每次提交只包含该任务源文件、夹具、必要生成物及报告，不使用无选择的整仓暂存。
- [ ] 在本计划指定的报告中记录基线提交、最终源文件 SHA-256、媒体哈希、设备/OS、命令、真实结果身份、失败和跳过；修复后仅重测受影响范围。
- [ ] 执行总览中的对应检查入口；新测试必须进入测试发现清单，不能只创建文件而没有运行。代码步骤先观察新增行为测试失败，再实现并通过。
- [ ] 对照本计划五项 Review Focus 和需求矩阵复核；只把实际通过的子行写进 `docs/platform-support.md`。仍缺输入的行保留具体解除条件。
- [ ] 更新总览的实施/验证状态。没有完整实现及实际验收时，不将整个 CAP 标为完成。

本文件是执行计划，以下检查命令属于未来执行步骤；编写本计划本身没有运行播放器测试或证明新增能力。

Task1工程调查已提交的内容不等于原始参考/画质验收完成。当前系统/候选未证明完整目标可行，Task2/3不得绕过独立参考与容差门槛。

2026-09-28 Task1B1 已完成六个arm64候选库构建，libdovi三端C API链接；macOS libplacebo13通过/1 GPU跳过、libdovi2单测及5个C API退出预期匹配。官方P5 1080p完整媒体hash已核验，首RPU为CM2.9/L1/L2/L4/L5/L6。独立目标参考、原始P7 FEL、容差及实际GPU/设备链仍缺，Task1整体不勾选。

2026-09-29 Task1B2 的macOS GPU子实验完成：固定候选在Apple M1加速CGL上执行原始GPU测试，含浮点往返及10-bit位对齐断言；非全功能验收。compute/SSBO相关功能、FEL增强层、独立画质与物理信号仍未验证。新实验记录和原EGL跳过记录分开。原始P7 FEL/独立参考/容差未取得，移动设备不可用，1B2及Task1保持未完成，Task2/3不提前开始。
