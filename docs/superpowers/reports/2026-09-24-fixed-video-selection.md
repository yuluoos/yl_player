# 固定视频档位：Android 首阶段

上阶段已按请求提交：播放器 `9f6b490`、TVS `9c183fd`，均未推送。本阶段三个任务及整阶段独立复审均已通过，现按用户请求随本次提交交付。

本阶段依据[固定档位设计](../specs/2026-09-24-fixed-video-selection-design.md)交付公开自动/固定状态与 Android Media3 单轨固定选择。公开 `selectVideoTrack(trackId)` 使用当前 `state.videoTracks` 的 ID，`null` 返回自动；`state.videoSelection` 的 `initial`、`user`、`trackUnavailable` 原因说明模式来源。Apple 固定命令明确 unsupported，已有 Apple 自动多档位路径继续可用。Android 原生使用单轨 override 和跨 Period 的语义质量身份；缺档时按照 PD-01 返回自动。SPI major 为2，Android 私有 wire schema 升至4，Apple仍为3。

## 实现与受控播放证据

公开验收新增两个 Android 用例，共用已有分别编码的 AVC 320×180 / 640×360 和 AAC 字节。原 `manifest.mpd` 保持不变：两段均有高档，第二段更换 Representation ID 并反转顺序。新 `manifest_missing_high.mpd` 仅删除第二段高档声明，保留低档与音频；所有媒体字节复用。两个清单及媒体可由 `SHA256SUMS` 审计。

设备验收使用自有临时 AVD `yl_player_fixed_task3`，ADB ID `emulator-5580`，已安装系统镜像 `android-36/android-tv/arm64-v8a`，主机 JDK17。从 `packages/yl_player/example` 运行：

```sh
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
flutter test --no-pub integration_test/android_video_selection_test.dart \
  -d emulator-5580 --reporter expanded
```

最终复审修正后的设备重跑 **2/2通过**，构建与安装成功；完整日志为仓库 `.superpowers/sdd/2026-09-24-fixed-video-selection/task-3-r1-final-device.log`。保留高档用例从首次确认高档画面起，记录至8秒完成的所有状态 `rev5–44`：非空 geometry 均为360p，模式均为 fixed/user；第二段请求4个高档视频片段，完成位置8016ms。缺高用例先确认匹配会话首帧与360p geometry；在首次回退前的全部快照保持 fixed/user 和360p。首次 `trackUnavailable` 快照 `rev28` 位于 **4003ms**，其视频轨道目录只有180p，模式为 automatic/trackUnavailable，geometry 为180p；上一快照 `rev27` 为 `3945ms/360/fixed-user`。测试严格要求首次回退位置不早于清单明示的4秒 Period 边界，不以公开位置充当逐帧像素时间。第二段请求4个低档片段，统一时长8秒；seek至5秒后继续到5577ms，Stop后模式回到 initial/automatic。这里的画面证据是匹配会话的首帧事件及原生报告的 decoded geometry/state，不是逐帧图像像素分析。

首轮原断言曾输出 **2 passed**，但日志 `.superpowers/sdd/2026-09-24-fixed-video-selection/task-3-device-initial.log` 暴露连续公开状态 `rev27 3813ms/360/fixed-user`、`rev28 3942ms/180/fixed-user`、`rev29 4010ms/180/auto-trackUnavailable`。这些位置是状态采样点，并非逐帧像素时间；问题是同一 `rev28` 快照同时声明固定高档和低档 geometry。首轮绿色结果因此不计最终验收。缺高用例增加“首次高档确认后，凡仍声明 fixed 的快照，其非空 encoded height 必须保持360”的断言。

临时元数据诊断重跑中，新断言按预期失败：公开 `rev26 3937ms/180/fixed-user`。原生回调记录显示未来 Period 的低档 input 在当前仍为 Period 0 时进入解码器，随后 renderer 的 frame/size 回调早于权威 `tracks` 切到 Period 1。诊断日志位于 `.superpowers/sdd/2026-09-24-fixed-video-selection/task-3-diag-logcat.log`，测试完整日志为同目录 `task-3-diag-test.log`。原生修正把未来 Period 的 size 暂存到当前轨道/模式切换时再发布，同 Period 正常切轨仍可更新 geometry；临时诊断代码随后移除。该次重跑的保留高档用例另遇测试时序：`ready` 已达成但公开视频轨道列表尚未发布，读取360p轨道时抛 `No element`；测试已改为等待公开视频列表出现唯一360p轨道后选择。诊断日志只含 Period、位置、格式/尺寸及 presentation/release 元数据。

最终几何实现使用真实解码输出的 Format 与缓冲提交观察，保留 coded/display、裁剪、旋转和 PAR 的对应关系；输入预读不再参与输出尺寸配对。无操作 seek 保留待发布观察，实际 renderer reset/disable 与会话生命周期世代隔离旧回调。观察仅在几何或输出世代变化时投递工作线程，流映射存储有上限。此适配依赖锁定的 Media3 1.11.0 输出钩子；升级 Media3 或启用 VideoSink、tunneling、prewarming、扩展渲染器时，需要重新核对相关默认配置与回归。

## 验证边界

新增 Dart 目标文件 `flutter analyze --no-pub` 无问题；四个相关模型、会话、Android codec/schema 文件的定向 Dart 回归35项通过；夹具目录 `shasum -a 256 -c SHA256SUMS` 全部通过，`git diff --check` 通过。Task1 原有9个相关 Dart 文件103项通过；Task2 原生原门槛171项、后续 wrapper 修正16项，以及本次 geometry 复审修正后的定向45项通过。这些原生/Task1结果沿用对应任务的保留证据；本任务没有重复运行 Apple 或原生全套。过程中的首轮2项旧断言通过、诊断2项失败及较早的增强断言2项通过均保留为过程证据；最终验收采用首次回退边界断言也纳入后的最新设备2项通过。

设备观察覆盖受控清单、首帧、原生报告的 decoded geometry、公开状态、请求、统一时间轴、seek和Stop；不代表逐像素图像鉴定、弱网ABR定量、长期性能、通用DASH兼容、真机或最低系统矩阵。Apple 固定与动态梯度、业务UI和完整 CAP-ABR 保留为后续范围。历史[前一阶段报告](2026-09-24-dash-variants-and-live-integration.md)记录的是当时的 schema3 和尚未固定选轨的状态，未被改写。

维护记录：原有 AGP/Kotlin/JDK 构建提示未阻断验证；输出适配的旧 `renderOutputBuffer` 覆写及父类调用还带来新的弃用提示，不能将这些统称为既存警告。最终复审判定为非阻断维护项，随 Media3 升级核对输出钩子。原始测试与复审证据保留在本阶段 `.superpowers/sdd` 工作目录，未提交前不清理。

验收收尾：已停止并删除本次自建的临时 AVD，确认设备断开、临时目录不存在；用户已有 TV AVD 未改动。
