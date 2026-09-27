# DRM 契约：受保护显示与许可证边界（P06 Task 1/2）

2026-09-27。需求依据：REQ-01/03/13/15，[需求基线](2026-09-20-playback-expansion-requirements.md)及 [P06](../plans/2026-09-26-remaining-06-drm.md)。本节冻结后续实现的显示边界；第 3 节生产显示类型是**待 Task 3 实现的接口约定**；第 6 节 Dart 配置和许可证传输已实现，现有适配器仍拒绝 DRM 播放。原型只在 example Debug 生效，不接受 DRM 配置，不获取许可证，不声明保护通过。

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

新能力不得复用 `textureId` 表示保护级别，也不得插入旧 Pigeon enum ordinal。Task 2 增加可选配置准入标记；Task 3 随原生受保护会话增加独立消息；未实现能力的旧 adapter 对 DRM 请求在 load admission 阶段返回明确不支持，clear 请求保持兼容。

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

生产 bridge 命令约定：`attachProtectedView(playerId, surfaceId, sessionId, generation, viewId)` / `detachProtectedView(...)`，native 同一 owner queue 串行完成；ack 带原四元组。显示反馈 `protectedFrameReady(playerId, surfaceId, sessionId, generation)`。具体 Pigeon 类/方法由 Task 3 随原生会话一并生成，不能靠无版本约定的字符串拼装替代正式桥接。

mount/unmount 只改变呈现，不转移 player/session 所有权。dispose/replacement 先失效代际，再解绑 layer/surface/监听，待 decoder detach 确认后释放；迟到 readiness/密钥/ACK 不更新新会话。Android 不释放仍由 SurfaceView holder 管理的 Surface。Apple 初次画面依据当前 layer+item 的 readiness，不能沿用上一 item 的 true；原型以新 layer/player 验证隔离，正式实现可以优化但必须保留该语义。

候选 load 先完成密钥、策略与解码/输出能力核查；不得复用当前非安全候选 surface。安全候选预加载、原生显示切换、旧会话回滚的原子性仍由 Task 3 实现和验证；本轮原型不满足完整 YlPlayerSession 事务契约。不能在候选首帧未验证时误发正式 FirstFrame。

## 4. 能力、错误和秘密边界

能力报告至少分开：`schemeAvailable`（系统探测）、`secureOutputAvailable`（表面能力）、`secureDecoderAvailable`（实际 codec）、`requestedProtectionSatisfied`（当前许可证/设备/输出证据）。后三者允许 `unknown`，不能默认 true。真实授权验证必须另外记录设备、系统、模式、内容样本和当前输出链；不存在全局 `drmSupported=true` 推导所有内容的规则。

以下条件 fail closed：旧 adapter、平台/scheme 不匹配、模式不支持、安全 decoder 不足、保护输出不足、仍要求像素读取、严格策略无法执行、状态/代际不匹配。Task 2 已在正式错误表落地精确代码；这里不在 native 先发明未声明 public code。HTTP403 只证明许可证请求拒绝，不证明许可证过期。原型错误以 `probe.*` 命名，不能出现在生产 `YlFailureCodes`。

媒体 GET 与许可证 POST 是两个独立配置/传输边界。Task 2 的传输配置见第 6 节；密钥安装、更新触发与原生代际验证属于 Task 3，尚未实现。任何 key/license/certificate/body/URL/header 不进 toString、普通日志、异常文本和公开诊断。

## 5. 几何、字幕和保护验收

生产受保护视图不能沿用依赖 Flutter texture 的 FittedBox/Opacity 或像素变换假设。Apple 用 AVPlayerLayer videoGravity 和原生容器裁切；Android 用原生尺寸/布局处理 aspect fit/crop。首帧前显示黑色遮罩，显示条件不控制或授予安全权限。四方向旋转、裁切、HDR、外接与窗口变化须逐项验证；本轮只验尺寸更改，不声称旋转和裁切图像正确。

字幕由 P02 以同一节目时钟在独立 Flutter/native overlay 合成，不读取解密画面。Android hybrid composition 的层级、遮挡与触控，Apple 原生 view 的层级/外接、HDR 字幕亮度均是后续验收项。Debug 页面上的文字只用于布局参考，不计字幕安全合成通过。

不能用 DRM 截图、PixelCopy 或 CVPixelBuffer 来证明播放通过。真实保护验收需要授权流和服务、系统保护/密钥状态、实际显示观察、进度/seek/更新行为及物理输出链。缺少资源时状态是 `external_missing`，不能改成 passed 或“设备不支持”。

## 6. 已实现的 Dart 配置与许可证 POST

`YlNetworkSource.drm` 为可空 `YlDrmConfig`，clear 请求默认 null。使用 DRM 时必须显式给 `format`：Widevine 仅 DASH，FairPlay 仅 HLS；automatic 或非 HTTP(S) 源拒绝为 `drm.config_invalid`。配置参与 source 值相等和 hash，不进入 source 的字符串诊断。

- `YlWidevineDrm(license: YlDrmLicenseEndpoint, encryption: YlDrmEncryption.cenc)`；encryption 支持 cenc/cbcs，平台校验按第 2 节，Android API 未知时不得通过能力校验。
- `YlFairPlayDrm(license: YlDrmLicenseEndpoint, certificate: YlDrmBytes, contentId: YlDrmBytes)`；宿主显式提供授权证书（1..65536 bytes）及内容标识（1..8192 bytes）。本项不自动获取证书，不猜测 skd URL 到 content ID 的供应商规则。
- `YlDrmBytes(List<int>)` 复制并校验 0..255 的字节；通用容器最大 4 MiB；`bytes` 返回副本。内容、配置和 endpoint 的 `toString` 脱敏；字节相等不表示 DRM 授权验证。

`YlDrmLicenseEndpoint(Uri, {YlHttpRequest? request, Duration timeout = 10s, YlDrmPostReplay replay = never, int maxRetries = 0, bool allowSameOriginRedirects = false, bool allowInsecureLoopback = false, int maxResponseBytes = 4MiB})`：

| 边界 | 强制行为 |
| --- | --- |
| 地址 | HTTPS、无 userinfo/fragment、长度 ≤8192；仅显式 opt-in 允许 HTTP 数字回环 127.0.0.1/::1，用于受控测试 |
| 元数据 | `YlHttpRequest` 只承载独立的 headers/credentials，不继承媒体传输策略；保留头校验外另禁 content-type/accept-encoding 覆盖 |
| 请求 | `POST application/octet-stream`，挑战 1..1MiB，原样字节；固定 accept-encoding identity |
| 响应 | 仅 200 且非空的原样字节，最大 1..4MiB（可缩小）；content-length 和每个 chunk 都检查；拒绝非 identity 编码 |
| 格式 | Widevine challenge/response、FairPlay SPC/CKC 都是不透明 raw binary；不猜 JSON/base64 信封或剥离正文；服务需要包装协议时需后续显式适配 |
| 重试 | 默认 0 次；只有宿主声明 `explicitlyIdempotent` 才允许最多 2 次额外尝试，适用于传输失败或 502/503/504，共用总期限；不自动重试 401/403 |
| 重定向 | 默认拒绝；显式开启时仅同 scheme/host/port 的 307/308，最多两跳，拒绝环和 userinfo/fragment；跨源完全拒绝，连 challenge 也不转发 |
| 期限 | 0 < timeout ≤60s；单一期限覆盖连接、响应头、正文、重试和重定向 |
| 生命周期 | 每客户端最多 4 个并行请求；无等待队列；取消/close 立即使结果失效并终止连接，迟到响应不能改写已完成结果 |

公开 `YlDrmLicenseClient.send(endpoint, challenge, {YlDrmCancellationToken? cancellation}) → Future<YlDrmBytes>`；`close()` 幂等取消该客户端全部请求，关闭后不可复用。token 的 `cancel()` 幂等，可取消一组请求，预取消 token 不发 HTTP。无 dart:io 平台明确返回 unsupported。

当前传输不调用 CDM，不缓存或安装许可证，不解析有效期。未来 Task 3 每次系统 renewal/rotation challenge 都创建绑定当前会话代际的请求；replacement/stop/dispose 先取消旧 token，安装响应前再验证四元组。HTTP 200 只表示获得响应字节，不能表示可解密；普通 HTTP 错误不能作为过期证据。

`YlPlatformDrmSourceSupport.drmContractVersion == 1` 为可选 SPI 标记，只表示 adapter 理解配置且执行明确准入，不表示保护已验证。控制器在 assess/load 调用旧 backend 或取消在途 clear load **之前**拒绝无此能力的 DRM 请求；现有双端 codec 也拒绝 DRM，不能序列化成 clear。双端 schemaMajor 保持 4，现有 enum ordinal 不变；现有适配器都不声明该标记。

生产 protected view 的 attach/ACK、challenge/response Pigeon DTO 随 Task 3 原子会话一并实现，避免本项暴露没有原生接收方的占位桥接。此调整意味着 Task 2 配置/传输完成仍不能播放授权媒体。

实现依据：[Dart HttpClientRequest.followRedirects](https://api.dart.dev/dart-io/HttpClientRequest/followRedirects.html) 表明默认自动重定向可能把 POST 303 改为 GET，因此关闭自动行为；[abort](https://api.dart.dev/dart-io/HttpClientRequest/abort.html) 对已返回响应头的请求无效，因此同时使用 [HttpClient.close(force: true)](https://api.dart.dev/dart-io/HttpClient/close.html) 终止正文。本机 Dart3.12 在 TCP 已连接但 TLS 尚未完成时，仅靠该调用不能及时关闭连接；实现通过 RawSocket 保留握手期间的取消所有权，TLS 验证成功后适配为 HttpClient socket。公开客户端使用系统证书验证和直接连接，不开放证书忽略或代理选项；测试私有 CA 仅由内部测试入口传入。受控 TLS 的超时/取消 EOF、未信任证书拒绝及 1MiB 往返均验证。2026-09-27 核查线上文档；执行证据使用本机 Dart 3.12.0。

## 7. Task 2 正式 DRM 错误码

新增代码沿用现有 category/scope enum，均默认 retryable=false；许可证 POST 的内部重试仅按明确幂等许可执行。`load.cancelled` 表示 token/客户端关闭导致取消，不发布为当前媒体故障。普通 HTTP 状态不能推断过期；`drm.license_expired` 只为后续系统明确证据保留，本轮传输绝不发出。

- `drm.config_invalid`：The DRM configuration is incomplete or invalid. Check delivery format, certificate, content ID and license policy.
- `drm.unsupported`：This adapter does not support the requested protected playback path.
- `drm.scheme_mismatch`：The DRM scheme does not match this platform. Use Widevine on Android or FairPlay on Apple.
- `drm.encryption_mode_unsupported`：The requested encryption mode is unavailable on this operating system.
- `drm.license_denied`：The license server refused the request. Check authorization and license request configuration.
- `drm.license_expired`：The license has expired according to explicit DRM evidence. Renew authorization.
- `drm.license_timeout`：The license request exceeded its deadline.
- `drm.license_failed`：The license request failed. Check the connection and license service.
- `drm.license_redirect_rejected`：The license redirect was rejected by the POST policy. Configure the final license endpoint.
- `drm.payload_too_large`：The DRM request or response exceeds its byte limit.
- `drm.license_response_invalid`：The license server returned an empty or unsupported response.

## 8. Task 3 Android 系统密钥边界（分步实现）

先实现内部 `YlDrmKeySession`，每个候选独占一个系统 driver。其身份为 playerId/surfaceId/sessionId/generation；另以内部 epoch 和 requestId 隔离后台恢复及更新请求。系统调用在同一个 owner dispatcher 上执行，HTTP/桥接是可取消的挂起传输；所有返回安装前重新检查 epoch/requestId，stop、失败、dispose、后台释放先失效身份，再取消传输并释放 driver。传输需要接 Task 2 的许可证策略；本步注入的 fake 不代表真实服务。

状态依次为 idle/requesting/awaitingKeys/usable，后台为 suspended，终止为 failed/disposed。许可证 POST/提供响应成功均不直接代表 keys usable；仅当前 MediaDrm 的非空、全部 usable key-status 集合可确认。明确 expired 状态才报告过期；output-not-allowed 报保护不足；普通 HTTP 拒绝保持 license_denied。一次只允许一个请求；系统重复 key-required 事件合并，当前请求完成后最多补一个更新请求，所有等待（包括 key-status）受单次总期限约束。后台恢复重新创建系统会话和请求，不复用旧许可证回调。

Android 系统 driver 使用 Widevine UUID、streaming key type、系统 L1 会话请求和状态回调，不获取或暴露内容密钥。整个包的 API24 下限及 cenc/cbcs 格式门槛保持；此内部 driver 另要求 API28+ 的实际 per-session security-level 查询。API24–27 目前缺该证据，明确返回保护不足；不能将设置 securityLevel 属性当作实际 L1 证明。openSession 后实际安全级别不满足也释放并拒绝，不转 L3。L1 只是一项系统证据，不能替代 secure decoder、SurfaceView、HDCP 或实际播放验收。Provisioning 不与许可证 POST 混用；设备需要 provisioning 时明确拒绝，后续单独实现授权的系统 provision 请求。

新增正式错误码先冻结为：`drm.session_failed`（系统密钥会话失败）、`drm.protection_insufficient`（所需保护未满足）、`drm.provisioning_required`（设备 DRM 尚需初始化）。消息必须固定且有修复建议。它们沿用现有 category/scope，不改变 enum ordinal。生产受保护 view、Pigeon、Media3 和 Apple key session 仍需后续接入；当前 adapter 不声明 DRM 支持。

系统 API 依据：[MediaDrm.openSession(int)](https://developer.android.com/reference/android/media/MediaDrm#openSession(int))、[getSecurityLevel](https://developer.android.com/reference/android/media/MediaDrm#getSecurityLevel(byte[]))、[KeyStatus](https://developer.android.com/reference/android/media/MediaDrm.KeyStatus)，2026-09-27 核查。驱动忽略系统请求中的 defaultUrl，不自行联网。会话 owner dispatcher 上的 mutex 使外部系统调用及状态转换成为一个操作；即使注入内联 dispatcher，同步回调也需等该操作结束。许可证请求结束而仅等待 key-status 时，KEY_REQUIRED 可立即发起更新；不能等新许可证才能产生的 USABLE 来解锁更新。
