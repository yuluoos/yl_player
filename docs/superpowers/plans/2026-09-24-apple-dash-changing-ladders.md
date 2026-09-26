# Apple DASH changing ladders Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development. 用户已授权继续；现有 codex/fel-integration，基线76b99d7。不自动commit或push；原生和设备构建串行。

**Goal:** Apple静态明文DASH在兼容档位增删、分辨率变化时保持完整节目播放。

**Architecture:** 有界完整视频路径规划替换跨Period固定数组下标；复用私有HLS、AVPlayer和来源图。自动模式与公开固定控制分开。

**Tech Stack:** Swift/AVFoundation、既有Dart集成夹具；无新增依赖。

**Spec:** `docs/superpowers/specs/2026-09-24-apple-dash-changing-ladders-design.md`

## Global Constraints

- iOS15/macOS12下限；Android代码、公开API、Apple schema3/Android schema4/SPI2不改。
- 原预算全部保留；节目质量身份并集最多16，Representation总256，Period64。
- 新增变化路径仅同codec/Profile、同角色、同显示比例、兼容声明帧率及square SAR；不跨动态范围，不处理PD-02。
- 所有档位先验证，再生成媒体URL；共享资源取最严格凭据来源，不打印地址/头。
- Apple固定能力仍unsupported，不能宣称本批完成完整ABR。

## Review Focus

1. 新增中间档位或完全无公共档位：每条HLS路径仍含每个Period，不能索引错位。
2. 下一Period只有一个Representation时的颜色/帧率描述符：不能因count=1跳过变化家族校验。
3. 16档并集但每Period数量更少：并集超限要在closure前失败，不能指数展开。
4. 同原资源在不同路径重复引用：凭据剥离不可恢复，registry/URI/segment预算不按路径重置。
5. 实际AVPlayer自然切换和seek：两端必须观察两种geometry，不能仅MPD成功或仅分片请求就宣布分辨率切换通过。

## Task 1: Compiler admission and full-program paths

**Files:** `Shared/DASH/YlDashDocument.swift`、`YlDashHlsCompiler.swift`；必要紧凑`YlDashVideoPaths.swift`（若新增须核对Xcode/Pods自动纳入）；canonical `tool/consumer_fixtures/apple_flutter/RunnerTests/YlDashHlsCompilerTests.swift`及example iOS/macOS镜像、current-only inventory/hash。

**Interfaces:** 保持`YlDashHlsCompiler.compile`和`YlDashHlsPresentation`现有调用契约；内部规划返回每路径每Period的真实YlDashTrack。既有同梯度master/child身份保持；单路径叫video。

- [x] 添加有意义RED：两个Period高低集合删增可编译；路径按quality身份而非ID/顺序；单轨高低互换；最大bandwidth/resolution、路径去重。用真实生成playlist内容断言：
```swift
// low+high -> low: expected paths [low,low], [high,low].
// high -> low: exactly one deduplicated full path [high,low].
// low -> low+high: [low,low], [low,high].
// Each path has one discontinuity and correct period-specific init/segments.
```
- [x] 先验证原行为和新增兼容家族，按spec确定性floor映射；在closure前检查union16、歧义、兼容、对齐。编码规划单独保持紧凑；不按Period数组位置绑定质量。
- [x] 补负例：单Representation新段不绕过range/codec/profile/role/ratio/fps/SAR校验；fps24与24/1等价，24与25或missing不匹配；17个跨段唯一身份零emission失败，16接受；共用凭据与全局预算。
- [x] compiler+loader各平台定向GREEN，保留RED/GREEN xcresult/log/数量，镜像/current-only manifest一致，历史inventory不动。不要设备播放（Task2负责），不提交。
- [x] 任务独立复审，通过后交接接口与证据。

## Task 2: Apple runtime acceptance and support record

**Files:** `packages/yl_player/example/integration_test/apple_dash_changing_ladders_test.dart`；`assets/test_media/dash_variants/`新增high-to-low/low-to-high两个MPD与SHA/README，复用已有媒体/服务器；docs/platform-support.md、本阶段报告。若发现native bug先报告root协调，禁止静默扩大改动。

**Interfaces:** `DashServer.start(variants:true, manifestOverride:...)`，公开player.state、events和会话play/pause/seekTo/stop。所有变化模式仍videoSelection initial/auto，不新增Apple固定API。

- [x] 新增3例：high-only→low-only，low-only→high-only，既有missing-high多档清单。前两例必须实际观察两种输出尺寸，并在自然跨段、seek5s、seek1s后持续播放；第三例消费非一致梯度但不猜AVPlayer选择了哪条路径。
```dart
// Wait current-session first frame and initial expected geometry.
// Natural time >4.5s + second Period expected geometry; seek5 then seek1;
// assert correct per-period geometry after resumed progress, then completion.
```
- [x] 分别macOS/iOS执行单文件3用例，串行，保留实际日志/设备OS/输出尺寸/请求；无Android或Apple全套重复。目标Dart analyze、资产SHA审计与gitdiffcheck。
- [x] 更新精确自动变化支持边界、Apple固定/严格上限/弱网ABR仍缺；root更新架构入口旧状态，报告commit76b99d7和新增未提交阶段。恢复测试生成的xcconfig目标与自有设备状态。
- [x] 独立任务复审和最终整阶段复审；所有完成条件有证据后收尾。
