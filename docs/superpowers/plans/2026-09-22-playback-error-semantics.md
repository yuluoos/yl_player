# 播放器扩展第一阶段：明确且安全的错误信息

> For agentic workers: 使用 subagent-driven-development 执行本计划；测试先行，按任务审查。

**Goal:** 落实 REQ-13 的第一批真实故障映射，覆盖 ERR-02、ERR-03、ERR-09、ERR-12；不以错误码常量代替实际链路接入。

**Architecture:** 保留 YlFailure 和 Pigeon 数据结构。原生错误产生处只采用结构化证据；边界用包内固定文案，禁止透传异常描述。Dart 增加对应稳定码，消费者可按码本地化。

**Tech Stack:** Dart/Flutter，Kotlin/Media3，Swift/Foundation，JUnit/XCTest。

**Spec:** [需求基线](../specs/2026-09-20-playback-expansion-requirements.md)，[诊断契约](../../diagnostics.md)。

**执行状态（2026-09-22）：** 本批功能及审查修复已完成，验证与过程偏差见[实施记录](../reports/2026-09-22-playback-error-semantics.md)。以下清单保留原计划；初始完整基线与测试先行过程不作补造，实际证据以实施记录为准。

## Global Constraints

- 不接入商业 SDK；三端共用语义，Apple 共享实现覆盖 iOS/macOS。
- 不输出源地址、凭据、请求头、任意原生异常文本；未知原因不得猜测。
- 保留 scope、diagnosticId、取消、旧会话隔离和现有重试预算；retryable 不等于自动重试授权。
- 保持既有公开错误码；细化 DNS/HTTP 403 等有结构化证据的泛化错误，记录迁移语义。
- 不更改 PD-01/02/03，不扩大自动换源、软解或画质降级策略。
- 基线提交 1128897；保留未提交的 CONTEXT.md、ADR、需求文档，不回退既有 FEL 工作。

## Task 1: 贯通网络错误与 Apple 安全文案

**Files:**
- 修改 Android `YlFailureMapper.kt` 及实际 Media3/managed 错误产生和转换处，测试放相应现有 `src/test` 测试类。
- 修改 Apple `Shared/Diagnostics/YlAppleSafeDiagnostics.swift`、`Shared/Network/YlNetworkRequestPolicy.swift`、`YlNetworkByteSource.swift`，必要时新增同目录小型固定码表；保留已有错误路由。
- XCTest 修改当前 canonical `tool/consumer_fixtures/apple_flutter/RunnerTests` 与主示例 iOS/macOS `RunnerTests` 中对应类，保持逐字节一致，更新当前用例清单；固定提交中的历史来源及其哈希保持不变。
- 修改 `packages/yl_player_platform_interface/lib/src/model/failure.dart` 和 `docs/diagnostics.md`。

**Consumes:** 平台结构化异常、HTTP 状态、包内 NativePlayerError/YlFailureKind。
**Produces:** 稳定且安全的 YlFailure，不改变桥接字段。

- [ ] 读取真实调用链与测试入口，执行相关现有用例建立基线。
- [ ] 添加并运行失败测试：真实 UnknownHostException/NSURLError DNS → `network.dns_failed`；HTTP 403 → `network.http_forbidden` 且不可自动重试；普通 IO/未知异常不能猜成 DNS/403。
- [ ] 覆盖包裹异常和 session/command 边界，避免仅直接 mapper 调用通过、实际播放仍丢失细分原因。优先保持显式终止/取消/策略错误；原因链有界。
- [ ] 用结构化证据实现分类。禁止通过 message/diagnostic 字符串搜索识别 DNS 或 403；不能更改 managed retry 决策。
- [ ] 添加并运行失败测试：已知 Apple 杜比不支持/元数据不支持、超时、无硬解、取消有明确固定文案；未知错误说明原因未知。任意敏感 prose 不得泄漏，重复桥接保留分类。
- [ ] 实现固定安全提示（沿用包内英文约定，可按稳定码本地化），给出环节、已知原因和合理建议；不把未知错误描述成已知根因。
- [ ] Dart 增加已落地稳定码并更新诊断文档：分类依据、旧泛化码变化、retryable 规则及本阶段未覆盖项。
- [ ] 定向检查：Android `./gradlew :yl_player_android:testDebugUnitTest`（example/android）；Apple `xcodebuild test` 对相关 RunnerTests 类；Dart `flutter test` 对 interface failure/桥接相关测试。记录具体命令、红绿证据和受限环境，不能用构建成功代替运行通过。
- [ ] 自审差异后提交任务报告供独立审查；不提交其他已有文档改动。

示例行为断言：`mapper.toMessage(UnknownHostException(secret)).code == "network.dns_failed"`；`HTTP 403` 的 message 含明确拒绝和请求配置建议，但不包含 secret，retryable 为 false。非 DNS NSError(domain: 自定义, code: -1003) 不应被误认成系统 DNS 失败。

## 后续阶段与依赖（不是本阶段完成声明）

1. Apple DASH 路由、DRM 受保护渲染、完整 Dolby 映射/外接链路可行性：先取得系统/开源依据与可运行验证，再细化实现计划。
2. 明文 DASH、Period 时间轴和三种清晰度策略；跨段缺档及动态范围切换受 PD-01/02 约束。
3. 独立 JS 解析模块与九脚本契约、生命周期/资源限制；内核 RTMP 接入和两种直播模式。
4. 字幕与格式覆盖、软解限制；字幕故障恢复范围受 PD-03 约束。
5. DRM 真实许可证、杜比参考与外接设备条件补齐后共同验收；性能先测基线再冻结优化目标。

本阶段不宣称 ERR-01/04–08/10–11、全部 CAP 或整轮交付完成。
