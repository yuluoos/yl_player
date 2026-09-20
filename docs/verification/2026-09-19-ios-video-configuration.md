# iOS 百度原画：打开阶段的视频配置失败

本次日志为 `phase=opening`、约 1283 ms 后出现 `decoder.video_configuration_invalid`，线路为“百度原画”。这是打开阶段的独立故障线索，尚不能与此前“波波秒播”中途有声音但画面停止的问题归为同一根因。

## 已确认的代码路径

`YlPreparedFallback` 通过 FFmpeg 打开媒体并选择 H.264/HEVC 视频轨道，随后调用 `YlVideoToolboxDecoder.makeFormatDescription` 创建 CoreMedia 视频格式描述。该调用失败时，命令返回 `decoder.video_configuration_invalid`。此时尚未创建该候选播放器的视频解码会话。

桥接层的 `YLFResultVideoConfigurationInvalid`（-8）合并了参数集解析失败与 CoreMedia 格式创建失败，原有公开错误不能区分这两者。采集接口 `play` 返回 HTTP 200 只证明接口成功响应，不能证明代理提供的媒体内容及解码参数完整、兼容。

## 新增现场证据

从包含本次改动的应用再次打开该影片，在 Xcode 原生控制台搜索 `[YLPlayer][VideoToolbox]`，保留 `event=videoConfigurationInvalid` 行。无需分享播放地址或凭据。

字段含义：

- `codec`：已识别到的 h264、hevc；无法取得有效流信息时为 unknown。
- `streamIndex`、`width`、`height`：视频轨道及其分辨率，-1 表示未知或不适用。
- `configBytes`：FFmpeg 提供的编码配置数据长度；0 表示无可用配置，非零不代表配置有效。
- `bridgeResult`：桥接层返回值。-8 不是 CoreMedia 的原始 OSStatus，不能据此断言特定硬件/编码能力缺失。

只记录固定标签与数字元数据，不记录配置字节、URL、请求头或任意错误描述。公开 `YlFailure` 协议及原有错误码保持不变；本次没有改解码策略或跳过参数校验。

## 验证

使用实际 Swift 格式描述方法及仓库 macOS 桥接 framework 运行两项现有 XCTest 方法，扩展断言检查失败诊断。修改前两项测试出现 6 个预期断言失败，修改后两项通过，并实际输出了新日志。fixture/example 对应测试同步。

iOS `build-for-testing` 成功（`ARCHS=arm64`、`IPHONEOS_DEPLOYMENT_TARGET=15.0`，仅命令行覆盖）。首次 generic 模拟器双架构构建触发 Flutter 框架复制脚本错误，使用 arm64 后通过；没有修改项目架构设置。本次未执行 iOS 模拟器播放测试。编译日志位于 `/private/tmp/yl-video-config-ios-build-arm64.log`。

上述验证仅覆盖诊断信息。随后通过 TVS 消费应用取得了真实失败证据，见下文。

## TVS 现场定位（2026-09-19）

TVS 的 pubspec、Dart package 配置和 iOS 插件路径均指向本工作区的 Apple 插件。运行中的模拟器应用二进制包含新诊断，原生系统日志实际记录：

```text
[YLPlayer][VideoToolbox] event=videoConfigurationInvalid stage=formatDescription codec=hevc streamIndex=0 width=3840 height=1616 configBytes=23 bridgeResult=-8
```

TVS 的 Dart Logger 使用 `dart:developer.log`，与原生 `NSLog` 属于不同日志来源，因此用户提供的 Dart 日志没有上述原生行，并不代表依赖没有更新。

从仍有效的本机媒体代理以 Range 请求读取 64 KiB，响应为 206，文件签名为 Matroska。仅将临时媒体头用于本机诊断，未将媒体、代理地址或凭据加入仓库。ffprobe 检查结果：

- 视频为 HEVC Main 10，3840 × 1616；存在 Dolby Vision profile 5 配置。
- 容器中的 hvcC 正好 23 字节，`numOfArrays` 为 0，确实没有 VPS/SPS/PPS。
- 首个视频包是时间戳 0 的关键帧包，使用 4 字节 NAL 长度前缀。其中存在类型 32、33、34 的完整参数集，长度分别为 25、59、6 字节。

用仓库实际 macOS YlFFmpegBridge 二进制做隔离验证：原始 23 字节配置返回 -8；将首包中的三个参数集装入 hvcC（共 128 字节）后，同一个桥接 API 返回 0，CoreMedia 格式尺寸为 3840 × 1616。

因此，这次启动失败可以定位为：参数集存在于视频包中，但当前打开路径只用容器配置创建格式描述，未补取包内参数集便提前失败。修复需要处理该种带内参数集配置，并保留预读包与正常播放、seek、取消和缓冲预算的正确关系，不能简单丢弃首包或忽略格式校验。

这是格式创建阶段的根因验证，未验证该 Dolby Vision 文件的实际解码、色彩或持续播放，也不能由此认定早先“波波秒播”中途卡画面具有相同根因。

## 已接入的修复

`YlPreparedFallback` 对可 seek 的 Matroska 输入，在 HEVC 配置恰为 23 字节且没有参数集数组时，调用 `YlHEVCInBandConfiguration`。该流程最多检查 32 个包、累计 8 MiB，遵守单包预算，并为临时参数配置和当前包预留 managed buffer 额度；逐包检查取消并释放包。它按原 hvcC 的 NAL 长度字段解析包，补齐 VPS/SPS/PPS，创建格式成功后 seek 到起点再交付播放流程。正常配置和其他容器不进入预读。

成功恢复的配置带入 managed session。本地同源重新激活时复用该格式创建新解码器，避免重新读取仍缺参数集的容器头。普通来源和 live reconnect 保留原路径；未改 FFmpeg 桥接二进制或公开协议。

### 本轮验证边界

- 新增 6 项 XCTest，并同步 example/fixture。前 5 项使用产品 helper、真实 macOS 桥接二进制和仓库自有合成 HEVC 内容执行，通过；其中首次运行缺实现的 stub，格式恢复和取消两项按预期失败，再接入实现通过。
- 合成 Matroska 在测试内生成，不引入用户媒体。测试覆盖首包内容、时间戳及关键帧保留，seek 后重读及 sample buffer 所有权转移，完整配置不预读，取消/单包上限，截断 NAL 拒绝，seek 失败传播和资源释放。
- 第 6 项通过真实 `YlPreparedFallback` / `YlFallbackBackend` 加受控 VT/显示实现，覆盖本地 deactivate/activate 不丢失恢复格式。该项目前只完成 iOS 编译，没有运行通过的证据。
- 使用产品 helper 读取真实媒体的临时 64 KiB 前缀，得到 128 字节配置、3840 × 1616 格式；seek 后重新读到首包，PTS 为 0、关键帧标记为 true、1935 字节。媒体前缀被截断导致 FFmpeg 的 premature EOF 提示，不代表验证了完整播放。
- 最终 iOS `build-for-testing` 成功：`/private/tmp/yl-inband-ios-build-final.log`。曾尝试运行定向 iOS XCTest，但模拟器随后处于 Shutdown，测试未启动；已中断本任务等待中的 xcodebuild，未计为通过。
- 测试清单与 fixture 一致性检查通过：iOS 433、macOS 349。这是清单校验，不是上述全部用例执行通过。

TVS 启动修复版本曾构建、安装并启动成功，但应用初始停在订阅加载失败，未完成同片源端到端播放验证。包含同源恢复修复的最终 TVS 模拟器构建也已通过；因模拟器已关闭，仅构建、未再次安装启动。用户仍需在最终原生构建上确认首次播放、seek、切集及长时间播放；不能仅凭格式恢复成功宣称原先中途卡画面已修复。
