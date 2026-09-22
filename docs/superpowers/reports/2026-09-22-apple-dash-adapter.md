# Apple 静态 DASH 适配实施记录

本批已实现 Apple 静态明文 DASH 基础播放及相关生命周期修复，最终 macOS、iOS 公共集成均 13/13 通过，Android 共享夹具回归 6/6 通过。执行依据为[本批计划](../plans/2026-09-22-apple-dash-adapter.md)和[已授权需求](../specs/2026-09-20-playback-expansion-requirements.md)。这不是通用 DASH 或整项播放器升级完成声明。

## 实现结果

显式 `YlMediaFormat.dash` 和自动识别 `.mpd` 的 HTTP(S) 点播源进入 `.dashHls` 检查路线，公开引擎仍为 AVPlayer，原始 DASH 源身份保留。有界 MPD 编译器生成会话私有 HLS 清单，虚拟清单仅从本地注册表读取；未知身份和错误资源种类在网络之前拒绝。真实初始化段和媒体段全部经现有 loopback 代理，包括未配置凭据的请求。没有接入商业 SDK、新媒体依赖或新的公开桥接协议。

当前子集是静态明文 AVC 视频、可选 AAC-LC 音频，每 Period 每类一个 Representation；对应 codec、尺寸、采样率、声道、角色及音频存在性一致。Period 有限连续、从零开始、PTO 为零；支持有限 SegmentTemplate/Timeline、SegmentList、分层单一 BaseURL、初始化段和媒体 Range。未实现的时间偏移/显式编号属性在继承前拒绝，不能默默忽略后生成错误地址或时间轴。

源 origin 与 MPD 最终响应地址分别承担凭据原点和相对路径解析职责。任一跨域祖先或 HTTP 重定向都会永久剥离凭据，返回原域和恢复资产也不能恢复；普通请求头保留。重复实际 URI 取最严格的凭据历史。MPD 403 使用已知状态产生 `network.http_forbidden`；编译拒绝使用固定 `container.unsupported`，MPD 字节超限使用 `resource.dash_manifest_too_large`，不透传 URL、请求头、响应体或原生异常。

| 资源 | 上限 |
|---|---|
| 原始 MPD | 2 MiB |
| XML 深度 / 元素 | 64 / 100,000 |
| Period / 展开媒体段 | 64 / 100,000 |
| 单 URI / 累计保留 URI | 8,192 / 4,194,304 UTF-16 单元 |
| 单生成清单 / 整个虚拟清单注册表 | 2 MiB / 4 MiB |

这些是解析与注册表上限，不能当作媒体缓存账本。`network.managed`、`buffer.bounded`、`hardwareRequired` 仍明确拒绝；本批继续沿用既有平台和策略边界。

## 验证与证据

媒体均为仓库自制夹具：两段各 4 秒、AVC Constrained Baseline 320×180/24fps、AAC-LC 48kHz/mono。`assets/test_media/dash/SHA256SUMS` 的 23 个文件全部校验通过，主 MPD SHA256 为 `9ed58044accfc270c83f08708fa227ddc12de96b77e8e63b6c061e0e6128ce9a`，未下载第三方媒体。运行环境为 macOS 27 arm64、iPhone 18 Pro / iOS 27 arm64 模拟器；Android 回归使用既有 API 36 模拟器。

| 验收行 / 需求 | 执行结果与边界 |
|---|---|
| CAP-DASH-APPLE-PARSE / REQ-02、REG-NET | 编译器 macOS、iOS 各 20 项通过；涵盖继承、时间轴、Range、凭据祖先和资源边界 |
| CAP-DASH-APPLE-ROUTE / REG-LIFE、REG-NET、REG-AUDIO | 初始接入定向 macOS 61/61、iOS 74/74；仅修改测试大清单等待参数后补跑 macOS 1/1。后续生产修复另列，不把早期结果当作最终代码全量结果 |
| CAP-DASH-APPLE-CANCEL / REG-LIFE | 请求创建与取消竞争修复后，相关 macOS 18/18、iOS 30/30，通过且无跳过 |
| CAP-DASH-APPLE-CONTROL / REG-LIFE、REG-AUDIO | 活跃播放及停用后的意图修复后，相关 macOS 17/17、iOS 18/18，通过且无跳过 |
| CAP-DASH-APPLE-PLAY / REQ-02、REQ-04，macOS | 最终公共集成 13/13；首帧、8 秒时长、自然跨 Period、前后 seek/继续播放/完成、凭据、错误、取消和策略拒绝全部通过，无崩溃 |
| CAP-DASH-APPLE-PLAY / REQ-02、REQ-04，iOS | 最终公共集成 13/13；与 macOS 相同的 13 个场景全部通过，完成位置 8022ms，无崩溃 |
| REG-DASH-SHARED / Android | 6/6 通过；修正原有测试的异步断言顺序后，确认共享服务兼容 |
| 当前 / 历史测试来源 | 当前 493 iOS / 409 macOS 声明、镜像及 PBX 注册通过，固定历史版本校验通过；声明数不是本批实际执行总数 |
| 独立审查 | 编译器、加载器、请求取消竞争修复、活跃播放/音频意图修复、最终测试与整体集成复核全部通过；无遗留审查问题 |

macOS 最终运行观测时长 8000ms，自然位置从零推进至 4750ms 后才进行 seek；跳到 5 秒后继续超过 5.5 秒，回到 1 秒后继续超过 1.5 秒，最后完成于 8008ms。固定断言为时长误差不超过 50ms、seek 落点误差不超过 300ms、自然跨过 4.5 秒、完成位置至少 7.5 秒。验证了当前会话首帧、非零画面尺寸、选中音频信息和两个 Period 的音视频初始化/媒体请求；不把预取下一段当作播放跨段，也不复用一次性 firstFrame future 证明 seek 后新帧。

13 个公共场景包含：Range 越界 416；显式与自动播放；三种 BaseURL 凭据模式；MPD HTTP 跨域再返回；挂起无效候选时旧源继续播放、暂停/恢复及回滚；挂起 MPD 时停止或直接换源；媒体已提交但挂起时停止重开；根 MPD 403；缺失媒体的安全失败；三种严格策略在任何请求前拒绝。所有已观察请求逐一检查凭据历史，日志仅记录安全路径、阶段和布尔状态。

缺失媒体在 macOS、iOS 均观测为 `avplayer.first_frame_timeout`，未输出首帧。它是实际可得的安全失败，不将 AVPlayer 媒体失败猜成公开 HTTP 404/403；根 MPD 的已知 403 则明确归类。

公共回归命令从 `packages/yl_player/example` 执行：

```sh
python3 ../../../tool/run_with_display_awake.py flutter test integration_test/apple_dash_playback_test.dart -d macos --reporter expanded
flutter test integration_test/apple_dash_playback_test.dart -d A2A68268-6CBC-4D9B-AA8F-FA81CDC30FA6 --reporter expanded
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home YL_ANDROID_DEVICE_ID=emulator-5554 sh ../../../tool/run_android_integration.sh integration_test/android_dash_playback_test.dart
```

最终公共集成日志为 `/private/tmp/yl-dash-task3-macos-final.log`、`/private/tmp/yl-dash-task3-ios-final.log`、`/private/tmp/yl-dash-task3-android-green.log`，三次均以退出码 0 完成。原生命令、实际用例树、RED/GREEN、完整日志路径及审查记录保留在 `.superpowers/sdd/2026-09-22-apple-dash-adapter/` 的任务报告中；最终 iOS 活跃播放补验为 `/private/tmp/yl-dash-task3-active-play-final-ios-retry.xcresult`。

最终三个 Dart 文件静态检查无问题，格式检查为零变化，`git diff --check` 通过。两端生成的 Flutter 配置及导出脚本已恢复 `FLUTTER_TARGET=lib/main.dart`；本任务启动的模拟器已关闭。

## 实际运行发现并处理的问题

- 编译器审查发现额外时间偏移和显式分段编号被忽略：新增两项真实失败回归，在继承前实施明确属性准入，修复后 20 项通过并复核通过。
- 首次完整 macOS 播放暴露已失效 URLSession 上创建任务导致 SIGABRT。代理和清单加载器统一有效性检查、创建、登记和启动的同步范围；两个可控时序用例先失败再通过，最终完整 macOS 重跑无崩溃。
- 活跃的 HLS/DASH 普通 Play 曾重建资产并取消正在预检的新候选。只在后端未激活时重建，保留当前资产和候选；DASH 与带凭据 HLS 均有先失败再通过的回归，真正 suspend/resume 仍重建并保留凭据上下文。
- 已停用 AVPlayer 的迟到非零 rate 曾重新产生内部播放意图。仅在后端活跃时使用原生 rate，保留明确请求的意图；新增确定性失败回归，原音频中断断言保持不变。
- 共享测试服务原本会在 EOF Range 上执行反向 clamp 并抛异常。实际应用内先复现，再修复为正确 416，保留回归。
- Android 原有测试把暂停后的 seek 位置更新当作媒体请求已完成。当前服务和修改前服务都复现同一断言失败，排除共享服务新增行为；保留第二 Period 请求断言，将其放在既有恢复播放并超过 5.5 秒的等待之后，不添加固定延迟、不删除验证。

资源释放测试最初在 Foundation 自动释放池结束前断言，结束测试持有作用域后原弱引用和账本断言通过，无生产规避修改。大规模清单测试最初先触发过短的测试等待期限，仅调整该用例的等待参数，生产超时和资源拒绝/清理断言不变。一次 iOS 原生测试卡在 Xcode 诊断收集，保留日志后中断该次操作，不计通过；同代码关闭该诊断收集后定向重试 18/18、退出码 0。

Android 前两次启动因模拟器系统服务无响应、VM service 连接中断而未执行用例，不计入测试结果。保留数据冷启动本任务模拟器后才进行实际回归；对照失败和修复后结果分别保存。

上一阶段私有 schema 3 迁移还遗留一处当前条件跳过校验值：逐字节证明源文件仅三处 schema 字面值变更后，更新当前绑定并保留旧哈希和原因，硬件跳过条件与固定历史清单不变。旧独立 consumer 迁移工具仍有既存 destination 哈希漂移，本批没有重写历史来源，也没有宣称整个 consumer 矩阵完成。

## 未完成范围与工程决定

动态/加密 MPD、SegmentBase、非零时间偏移、缺口/重叠、任意轨道/编码变更、多 Representation/ABR、字幕和 DRM 仍需后续实现及验证，完整已确认需求不因此缩减。当前结果不证明真实声画同步误差、物理 iOS 设备、最低 iOS15/macOS12、长时间稳定性或性能提升。JS、RTMP、杜比显示映射及其余整体验收也不属于本批完成声明。

沿用已有功能分支并保留全部前期未提交工作，后续需整理阶段提交。首批采用可验证的静态子集，代价是暂时拒绝部分有效 MPD；严格网络/缓存/硬解要求继续拒绝，代价是此类调用方暂不能使用该 AVPlayer 路线。未提交、未发布。
