# 播放器扩展首批实施记录

日期：2026-09-22。基线提交：1128897；工作分支：`codex/fel-integration`；本批改动保留在工作区，未提交、未合并、未发布。

范围对应 [REQ-13、ERR-02/03/09/12、REG-DIAG](../specs/2026-09-20-playback-expansion-requirements.md)，执行 [错误语义计划](../plans/2026-09-22-playback-error-semantics.md)。本记录不代表整轮播放器扩展完成。

## 已落地行为

- Android 与 Apple 依据结构化异常识别 DNS 失败，依据真实响应状态识别 HTTP 403，公开 `network.dns_failed`、`network.http_forbidden`。不搜索异常文字猜测原因。
- Android Media3 播放错误保留 cause 供分类；直接 mapper 和播放器分类都优先保留显式取消/包内错误。原因链有深度与循环限制。
- Apple 共享实现为 DNS、403、连接/读取超时、杜比 Profile/显示元数据不支持、硬解不可用、取消和重试耗尽提供固定安全文案；未知原因明确说明未知。
- 不改变重试次数、退避、换源或画质降级策略。Apple managed 请求原有的 `network.retry_exhausted` 终止结果继续保留，不为了显示 DNS 码而削弱预算语义。
- Dart 导出两个新增稳定码；已有桥接字段、scope 和关联标识机制保留。文案沿用包内英文约定，应用可按稳定码本地化，详见[诊断契约](../../diagnostics.md)。
- 当前 Apple 公共测试模板与 iOS/macOS 示例同步；历史来源与固定哈希不改写。

## 验证结果

| 检查 | 结果 | 范围与限制 |
|---|---|---|
| Android JVM 全量 | 34 个测试类、308 项通过；0 失败/错误/跳过 | JDK 17.0.19；包含真实 403 异常、原因链优先级、Media3 分类与 Flutter 边界断言；不是 Android 真机播放验收 |
| Dart platform_interface | 105 项通过 | 公共模型/接口测试 |
| macOS XCTest | 77 项通过；0 失败/跳过 | YlNetworkRequestPolicyTests、YlNetworkByteSourceTests、YlApplePublicationTests |
| iOS 模拟器 | 初轮关键 3 项通过；修复后的新增 2 项通过 | iPhone 18 Pro / iOS 27；仅选定用例，不是完整 iOS 测试矩阵或真机验收 |
| Apple 当前源码门禁 | 通过 | iOS 453 / macOS 369 为声明清单数量，不是本次全部执行数量 |
| Python 测试模板/来源检查 | 37 项通过 | 当前模板一致性、来源与历史哈希等检查 |
| 差异格式 | 通过 | `git diff --check` |
| 独立审查 | 复审通过：Spec compliant / Approved | 两处取消优先级问题、缺失边界覆盖、当前模板门禁均已解决；复审未发现新增实质问题 |

Android 先前用 JDK 22 运行全量测试时出现 Mockito/ByteBuddy instrumentation 失败；切换本机已安装 JDK 17 后完整套件通过，无依赖升级或无关测试绕过。Apple 测试仍有 Swift Sendable、弃用、部署链接及 QoS 警告；测试通过不等于这些既有警告已解决。

初轮 DNS/403 的失败演示是在实现后临时回退分支完成，属于回归敏感性验证，不能作为完整“测试先行”过程证据。审查修复轮先添加并运行取消优先级/耗尽提示测试，记录真实失败后再修改生产代码并验证通过。未留存匹配的完整改动前基线，因此不声称完成了性能基线或所有既有行为的前后对照。

### 复现入口

Android，在 `packages/yl_player_android/example/android`：

```sh
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ./gradlew :yl_player_android:testDebugUnitTest
```

Dart，在 `packages/yl_player_platform_interface`：`flutter test`。

macOS，在 `packages/yl_player/example`：

```sh
xcodebuild test -quiet -workspace macos/Runner.xcworkspace -scheme Runner \
  -destination platform=macOS -parallel-testing-enabled NO \
  -only-testing:RunnerTests/YlNetworkRequestPolicyTests \
  -only-testing:RunnerTests/YlNetworkByteSourceTests \
  -only-testing:RunnerTests/YlApplePublicationTests
```

当前模板检查，在仓库根目录：`python3 -B tool/consumer_fixtures/apple_flutter/main_example_tests.py --current-only`。

本次 Android 日志 `/private/tmp/yl-error-semantics-android-full-jdk17.log`，JUnit XML 在 `packages/yl_player_android/example/build/yl_player_android/test-results/testDebugUnitTest/`；macOS/iOS 日志分别为 `/private/tmp/yl-error-semantics-apple-related-macos.log`、`/private/tmp/yl-error-semantics-apple-fix-ios.log`。详细执行和审查记录在本地 `.superpowers/sdd/2026-09-22-playback-error-semantics/`。这些运行产物可能被后续构建或系统清理，本文件不把它们当永久归档。

## 后续能力与工程取舍

DASH、DRM、JS、RTMP、多 Period、字幕、更多格式和完整杜比映射尚未在本批实现；见[架构核查与实施入口](../plans/2026-09-22-playback-feasibility.md)。PD-01/02/03 仍待确认；合法 DRM 资源、独立映射参考和外接设备条件仍缺。

本批沿用现有功能分支及构建缓存，未创建新 worktree；保持改动未提交，便于在现有工作区审查。若后续要求独立交付，需要迁移/提交本批差异。当前 canonical 测试模板随功能修改同步，历史快照维持原样；相应风险由来源和一致性门禁检查。
