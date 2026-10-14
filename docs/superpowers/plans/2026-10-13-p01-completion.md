# P01 完整节目播放 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans；保留当前会话 inline 方式，最终一次 fresh review。

**Goal:** 完成 P01 Task 3/4 及必要的字幕、解码重配和短时测量依赖。

**Architecture:** 保留既有 HLS 适配；新增精确节目模型、受预算控制的分段供应及样本调度，复用原生输出。各平台使用同一 owned 媒体参考验证。

**Tech Stack:** Swift/CoreMedia/VideoToolbox、Kotlin/Media3、Dart 字幕、Python 验证。

**Spec:** [已批准设计](../specs/2026-10-13-p01-completion-design.md)。用户 2026-10-13 明确选择按方案实施，并确认 PD-02/03 推荐规则；执行方式沿用当前会话。此文件细化已批准步骤，不另设重复授权门槛。

## Global Constraints

- 部署下限 Android API 24、iOS 15、macOS 12；不开商业 SDK、不 push。
- 保持 HLS 已验证路线、FEL 完整信息、硬解/固定档位/caps/网络凭据/资源限制。
- PD-02：自动切换限兼容画质集合。PD-03：字幕失败单独报错，继续视频。
- 另一会话的长播放、弱网 ABR、P05 不在此轮修改范围；共享文件编辑前检查变更归属。
- RED→GREEN 后运行受影响回归；完整任务末尾才汇总；跳过与缺设备不计通过。

## Review Focus

- 非整微秒时标、负 priming 与巨大数值不能溢出、错序或累计漂移（Task 1/3）。
- 空缺、重叠和被 caps 隐藏的非法轨道不能造成默认轨道替换或错误节目时长（Task 1/4）。
- BaseURL 回到原域不得恢复已剥离凭据；候选切换不能重置重试或缓存预算（Task 2）。
- cancel/seek/后台与重配并发时，旧结果不能覆盖新代际（Task 3/4/5）。
- 字幕/解码失败必须作用于正确范围；测量不得把解码或目录选中视为实际 AV 输出（Task 5/6）。

### Task 1: 精确节目时标与时间窗口

**Files:** 新增 Apple `Shared/DASH/YlDashProgramTime.swift`、`YlDashProgramTimeline.swift`；测试 `tool/dash_timeline/program_time_tests.swift` 和 `test_program_time.py`。

**Interfaces:** `YlDashProgramTime(numerator, denominator)`；`adding`/`subtracting`/`converted(to:rounding:)`；`YlDashProgramTimeline(periods:)`、`locate(time:)`、`map(sample:offset:period:)`。纯值层不执行 I/O，不改变旧 HLS admission。

- [x] 测试 `1/3 + 1/6 == 1/2`、负 priming、半开窗口、gap、overlap、巨大数值、未知边界和重复 seek。
- [x] `python3 -B -m unittest discover -s tool/dash_timeline -p 'test_program_time.py'`；预期缺少新实现而失败，补测试导入错误后再验证行为 RED。
- [x] 实现受检约分、确定的量化边界、Period 定位与源/节目互逆映射；不通过浮点比较决定边界。
- [x] 同命令 GREEN；原有夹具工具回归；限定提交 `feat: model exact DASH program time`。

### Task 2: 节目模型、分段与网络资源

**Files:** 新增 `Shared/DASH/YlDashProgramDocument.swift`、`YlDashProgramResources.swift`；复用现有 XML/SegmentBase 边界、managed transport、来源凭据策略；canonical `YlDashProgramTests.swift` 及镜像测试。

**Interfaces:** 不可变 program→period→track→segment，资源为 URL 候选/Range/凭据上下文；供应器 `read(resource:cancellation:)` 返回受预算管理的字节。

- [x] 用七维真实清单定义精确资源/时间预期；mock transport 检验跨域回原域、超限、Range 错误、取消、重试总预算。
- [x] 原 parser 拒绝而新模型应正确解析的用例先 RED；缺权威边界必须报错。
- [x] 从共享有界 XML 节点构建独立模型，保留未筛选原始轨道校验；多 BaseURL 的候选身份与凭据一起保留。
- [x] native DASH 测试 GREEN 后提交模型/资源层；生产路由仍待真实播放。

### Task 3: Apple 分段解码与真实时标

**Files:** 新增 `Shared/DASH/YlDashSampleSource.swift`、`Engines/DashProgram/YlDashProgramBackend.swift`；最小修改准备/路由/会话接口；新增真实 fixture probe 和 native tests。

**Interfaces:** segment source 输出带解码配置及原始 PTS/DTS 的样本；节目 backend 实现 `YlPlaybackBackend`，与当前 session identity/commit emitter 绑定。

- [x] 原始独立 PTO 和 3.5 秒裁剪媒体定义实际颜色/PCM 预期，先观察旧路径失败。
- [x] 供应器保留初始化与当前窗口，复用已有解码/输出，PCM 裁剪及视频窗口在节目时标执行。
- [x] 实测节目 0.5/3.45/3.5/3.8 秒图像/声音时标、seek/停止/释放；缺样本时钟不作同步通过声明。
- [x] 验证通过再接正式 route；最小部署构建和既有 HLS/音频回归后提交。

阶段说明：早期 route/HLS 回归保留原记录；最终两端原生各 24/24、三端公开节目/取消及最低部署消费者已验证。macOS 通用架构消费者使用有严格负例的隔离 lipo 适配，默认工具链失败不隐藏。当前只剩一次最终复核与其必要修复。

### Task 4: 三端 Period 重配与选择

**Files:** DASH program controller、Apple source/commit 边界、Android 必要的局部 MediaSource/selector 适配；公开 `dash_program_periods_test.dart` 与 owned fixtures。

**Interfaces:** 同一 program clock；不可变已接受音轨意图；`session/command/period` 代际；现有视频固定/caps 命令。

- [x] 同编码分辨率改变、AVC↔HEVC 同动态范围、音轨增删、缺固定档位分别 RED。
- [x] 准备/切换/发布为事务；缺显式音轨 `track.not_found`，缺视频档位按 PD-01 回自动但保留 caps。
- [x] 实际自然跨段、前后 seek、重配中 cancel、后台恢复与重复释放；Android 用同媒体验证。
- [x] 通过后提交，并逐项保留不具备解码硬件的外部条件记录。

2026-10-14：三端节目矩阵、候选取消、Apple/Android 原生恢复、实际音画/字幕观测已完成；见 P01 报告与 4e70564。设备条件和最低部署构建在 Task 6 分开列出。

### Task 5: DASH 字幕与错误隔离

**Files:** Dart `lib/src/subtitles/dash_subtitles.dart`、subtitle runtime 与资源层；测试 MPD text、wvtt/stpp、外部 VTT/TTML 和跨段 widget/public。

**Interfaces:** 字幕内容身份、Period/PTO→节目 cue；现有 managed 请求与生命周期 token；独立 subtitle failure。

- [x] 字幕发现、选择、跨段映射、迟到请求、错误继续视频各 RED。
- [x] 复用现有解析/合成，不增加第二套样式实现；清除旧代际 cue；PD-03 错误不会终止视频。
- [x] 三端同一 cue/画面标记和 Dart widget/reference 校验 GREEN 后提交。

### Task 6: 短时基线、联合验证与封板

**Files:** `tool/dash_timeline/` 独立观测/统计、三端公开测试、P01/依赖报告与 evidence。

- [x] 在新路径优化前保存当前可播放对照，冻结媒体/设备/缓存/样本数；不可播放的新能力标记无可比基线。
- [x] 捕获实际画面/音频消费/cue 时标、重配等待及释放；测量缺失保留 null，失败不从统计删除。
- [x] 运行受影响 native、Dart、Pigeon、最低版本构建/消费者检查；完整 P01 行逐项核验。
- [ ] 一次 fresh final reviewer；Important/Critical 一次修复流程并 RED→GREEN；提交最终证据与文档。
- [ ] 只有规定功能/证据齐全才宣告 P01 完成；外部输入缺失如实列出，不改写成通过。
