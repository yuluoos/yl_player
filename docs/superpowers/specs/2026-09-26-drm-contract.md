# DRM 契约：受保护显示决定（P06 Task 1）

2026-09-27。需求依据：REQ-01/03/13/15，[需求基线](2026-09-20-playback-expansion-requirements.md)及 [P06](../plans/2026-09-26-remaining-06-drm.md)。本节冻结后续实现的显示边界；下面的生产类型是**待 Task 2 实现的接口约定**，当前公开包没有这些 API。原型只在 example Debug 生效，不接受 DRM 配置，不获取许可证，不声明保护通过。

## 1. 输出路线与现状

当前 Apple 的 `YlAvPlayerBackend` 依赖 `AVPlayerItemVideoOutput` 和 CVPixelBuffer 首帧/几何；`YlIosTextureOutput` / `YlMacosTextureOutput` 即使走 native view，也由 `YlSampleBufferVideoRenderer` 将已读像素交给 AVSampleBufferDisplayLayer。因此“native view 已存在”不等于“可播放 FairPlay”。Android 的生产 `YlCandidateVideoOutput` 用 `PlaceholderSurface.newInstance(context, false)`，正式输出依赖 Flutter surface；这些不能作为安全候选输出使用。

选择的后续路线：

- Apple：系统 AVPlayer + AVContentKeySession，直接 AVPlayerLayer。受保护路径禁止创建 AVPlayerItemVideoOutput、copyPixelBuffer、FFmpeg 解码、截图取帧或 sample-buffer 重合成。原生 `isReadyForDisplay` 提供当前 item 的显示就绪观察，不能证明授权/HDCP/物理画面成功。
- Android：Media3 + 系统 MediaDrm/Widevine，安全 SurfaceView；在 Surface 创建/attach 前请求 `setSecure(true)`，Flutter 使用 `initExpensiveAndroidView` 的显式 hybrid composition。不得自动回到 TextureView、virtual-display texture、非安全 PlaceholderSurface 或软件解码。secure 标志本身不是 Widevine L1、安全解码器或外接保护的证明。
- clear 内容沿用现有默认路径。新路径必须由 source 的 DRM 请求与已协商能力显式选用；不能把所有媒体切换到原型实现。

本地基线：Flutter 3.44.0 / engine 4c525dac5ebe5971c5708ef73558ed8edcf4a362；Media3 1.11.0；Xcode 27.0 (27A266a)。包下限保持 Android API24 / iOS15 / macOS12。

## 2. 模式与能力门槛

| delivery | 允许的后续工程范围 | 当前状态 / 必须拒绝的情况 |
| --- | --- | --- |
| Android DASH + Widevine cenc | 项目 API24+；系统支持对应 UUID、实际 codec 与请求安全等级 | 未实现。设备能力/安全 decoder/原生 surface 任一不满足则拒绝；不把可用普通 decoder 当 secure decoder |
| Android DASH + Widevine cbcs | API25+，其余门槛相同 | API24 明确拒绝 cbcs，不提高整包 minSdk |
| Apple HLS + FairPlay | iOS15/macOS12 项目下限内使用系统 FPS API；原生受保护显示 | 仅可行性原型。确切 HLS 加密封装、设备、证书/许可证与系统保护状态必须逐样本验证；不承诺任意加密 MPD 或两平台地址通用 |
| 离线/永久许可证、跨 DRM 转换、外接 DV 信号 | 不属于本轮实现范围 | 不新增隐式支持；外接保护和 DV 输出分别验收 |

API 可用性来自本地 SDK：AVContentKeySession/FairPlay 常量为 macOS10.12.4/iOS10.3 起；本项目仍保持更高的既有下限。设备上存在 API 不等于授权播放可用。

官方依据（2026-09-27 核查）：[Media3 DRM 模式表](https://developer.android.com/media/media3/exoplayer/drm)、[SurfaceView.setSecure](https://developer.android.com/reference/android/view/SurfaceView#setSecure(boolean))、[Flutter 显式 hybrid composition](https://api.flutter.dev/flutter/services/PlatformViewsService/initExpensiveAndroidView.html)、[AVPlayerLayer 就绪含义](https://developer.apple.com/documentation/avfoundation/avplayerlayer/isreadyfordisplay)、[FairPlay Streaming 概览](https://developer.apple.com/streaming/fps/FairPlayStreamingOverview.pdf)。FPS 概览是历史架构文档，不代替当前设备/授权验收。

## 3. 待实现的生产 view/bridge 契约

新能力不得复用 `textureId` 表示保护级别，也不得插入旧 Pigeon enum ordinal。Task 2 增加可选能力协商与独立消息；未实现能力的旧 adapter 对 DRM 请求在 load admission 阶段返回明确不支持，clear 请求保持兼容。

拟定不可变描述符 `YlProtectedVideoSurface`：

| 字段 | 精确类型 / 含义 |
| --- | --- |
| `playerId` | Dart int / native Int64，播放器所有者 |
| `surfaceId` | Dart int / native Int64，原生输出注册表身份，不是 Flutter texture id |
| `sessionId` | String，会话身份，与公开会话一致 |
| `generation` | Dart int / native Int64，替换/释放递增的输出代际 |
| `viewType` | String：`yl_player_apple/protected_video` 或 `yl_player_android/protected_video` |
| `platform` | 既有 TargetPlatform，必须与当前 adapter 匹配 |

可选 provider：`YlPlatformProtectedVideoSurfaceProvider` 的只读 `YlProtectedVideoSurface? get protectedVideoSurface`。StandardMessageCodec 创建参数为上述身份四元组 `playerId/surfaceId/sessionId/generation`；native 必须匹配所有字段和存活注册记录，未知、过期、重复占用返回空黑视图且不借用别人的 player，不静默选择最新 surface。

生产 bridge 命令约定：`attachProtectedView(playerId, surfaceId, sessionId, generation, viewId)` / `detachProtectedView(...)`，native 同一 owner queue 串行完成；ack 带原四元组。显示反馈 `protectedFrameReady(playerId, surfaceId, sessionId, generation)`。具体 Pigeon 类/方法由 Task 2 一并生成，不能靠无版本约定的字符串拼装替代正式桥接。

mount/unmount 只改变呈现，不转移 player/session 所有权。dispose/replacement 先失效代际，再解绑 layer/surface/监听，待 decoder detach 确认后释放；迟到 readiness/密钥/ACK 不更新新会话。Android 不释放仍由 SurfaceView holder 管理的 Surface。Apple 初次画面依据当前 layer+item 的 readiness，不能沿用上一 item 的 true；原型以新 layer/player 验证隔离，正式实现可以优化但必须保留该语义。

候选 load 先完成密钥、策略与解码/输出能力核查；不得复用当前非安全候选 surface。安全候选预加载、原生显示切换、旧会话回滚的原子性仍由 Task 3 实现和验证；本轮原型不满足完整 YlPlayerSession 事务契约。不能在候选首帧未验证时误发正式 FirstFrame。

## 4. 能力、错误和秘密边界

能力报告至少分开：`schemeAvailable`（系统探测）、`secureOutputAvailable`（表面能力）、`secureDecoderAvailable`（实际 codec）、`requestedProtectionSatisfied`（当前许可证/设备/输出证据）。后三者允许 `unknown`，不能默认 true。真实授权验证必须另外记录设备、系统、模式、内容样本和当前输出链；不存在全局 `drmSupported=true` 推导所有内容的规则。

以下条件 fail closed：旧 adapter、平台/scheme 不匹配、模式不支持、安全 decoder 不足、保护输出不足、仍要求像素读取、严格策略无法执行、状态/代际不匹配。Task 2 在正式错误表落地精确代码；这里不在 native 先发明未声明 public code。HTTP403 只证明许可证请求拒绝，不证明许可证过期。原型错误以 `probe.*` 命名，不能出现在生产 `YlFailureCodes`。

媒体 GET 与许可证 POST 是两个独立配置/传输边界。Task 2 仍需完整冻结证书、内容标识、body/response 类型、大小、超时、取消、重试许可、重定向、密钥更新与二进制脱敏；本文件当前不伪称这些已实现。任何 key/license/certificate/body/URL/header 不进 toString、普通日志、异常文本和公开诊断。

## 5. 几何、字幕和保护验收

生产受保护视图不能沿用依赖 Flutter texture 的 FittedBox/Opacity 或像素变换假设。Apple 用 AVPlayerLayer videoGravity 和原生容器裁切；Android 用原生尺寸/布局处理 aspect fit/crop。首帧前显示黑色遮罩，显示条件不控制或授予安全权限。四方向旋转、裁切、HDR、外接与窗口变化须逐项验证；本轮只验尺寸更改，不声称旋转和裁切图像正确。

字幕由 P02 以同一节目时钟在独立 Flutter/native overlay 合成，不读取解密画面。Android hybrid composition 的层级、遮挡与触控，Apple 原生 view 的层级/外接、HDR 字幕亮度均是后续验收项。Debug 页面上的文字只用于布局参考，不计字幕安全合成通过。

不能用 DRM 截图、PixelCopy 或 CVPixelBuffer 来证明播放通过。真实保护验收需要授权流和服务、系统保护/密钥状态、实际显示观察、进度/seek/更新行为及物理输出链。缺少资源时状态是 `external_missing`，不能改成 passed 或“设备不支持”。
