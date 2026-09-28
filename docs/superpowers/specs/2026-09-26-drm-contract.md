# DRM 契约：受保护显示与许可证边界（P06 Task 1/2）

2026-09-27。需求依据：REQ-01/03/13/15，[需求基线](2026-09-20-playback-expansion-requirements.md)及 [P06](../plans/2026-09-26-remaining-06-drm.md)。本节冻结后续实现的显示边界；第 3 节冻结生产显示接口；第 6 节 Dart 配置和许可证传输已实现。Android 3B3 的公共桥接现状见第11节，Apple 仍等待3C。原型只在 example Debug 生效，不接受 DRM 配置，不获取许可证，不声明保护通过。

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
| Android DASH + Widevine cenc | 项目 API24+；系统支持对应 UUID、实际 codec 与请求安全等级 | Android 公共工程路径已实现，当前视频硬件证据需 API29+；设备能力/安全 decoder/原生 surface 任一不满足则拒绝。授权真机未验收 |
| Android DASH + Widevine cbcs | API25+，其余门槛相同 | API24 明确拒绝 cbcs，不提高整包 minSdk |
| Apple HLS + FairPlay | iOS15/macOS12 项目下限内使用系统 FPS API；原生受保护显示 | 仅可行性原型。确切 HLS 加密封装、设备、证书/许可证与系统保护状态必须逐样本验证；不承诺任意加密 MPD 或两平台地址通用 |
| 离线/永久许可证、跨 DRM 转换、外接 DV 信号 | 不属于本轮实现范围 | 不新增隐式支持；外接保护和 DV 输出分别验收 |

API 可用性来自本地 SDK：AVContentKeySession/FairPlay 常量为 macOS10.12.4/iOS10.3 起；本项目仍保持更高的既有下限。设备上存在 API 不等于授权播放可用。

官方依据（2026-09-27 核查）：[Media3 DRM 模式表](https://developer.android.com/media/media3/exoplayer/drm)、[SurfaceView.setSecure](https://developer.android.com/reference/android/view/SurfaceView#setSecure(boolean))、[Flutter 显式 hybrid composition](https://api.flutter.dev/flutter/services/PlatformViewsService/initExpensiveAndroidView.html)、[AVPlayerLayer 就绪含义](https://developer.apple.com/documentation/avfoundation/avplayerlayer/isreadyfordisplay)、[FairPlay Streaming 概览](https://developer.apple.com/streaming/fps/FairPlayStreamingOverview.pdf)。FPS 概览是历史架构文档，不代替当前设备/授权验收。

## 3. 生产 view/bridge 契约（Android 已实现，Apple 待3C）

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

## 9. Task 3B1：Media3 密钥会话消费（内部，未开放准入）

`YlMedia3DrmSessionManager` 实现锁定 Media3 1.11 的实际 `DrmSessionManager`/`DrmSession` 接口，每个候选独立实例，绑定 Media3 提供的 playback Looper。声明的 cenc/cbcs 必须与格式一致；能力探测允许匹配 Widevine 元数据暂缺 PSSH，等初始化分片提供；实际 acquire 仅消费匹配 Widevine UUID、1..1MiB 的 MP4 初始化数据，缺数据仍拒绝。相同初始化数据在同一 prepare 周期共享引用；不同 Period/track 数据独立会话。同一格式若有不同 Widevine 初始化 payload 则明确拒绝，不猜测选取或拼接；不读取其 licenseServerUrl。clear 格式返回空 DRM session，不等于声明为受保护的整个 source 可以按 clear 准入，后续候选还需检查实际轨道。

每个 manager 最多保留 4 个系统会话，包含失败、旧 prepare 周期和待清理对象。回包身份新增不透明 `exchangeId`，避免相同 output 四元组下多个 CDM session 的 epoch/requestId 重合。跨桥接时必须原样保留此值并检查所属会话。manager release 不借机关闭 decoder 仍持有的系统会话；最后一个 consumer release 先同步失效，再取消传输和状态机，关闭系统并清零 handle。系统失败立即终止可用状态和在途请求，但 CDM close 推迟到最后一个 Media3 引用释放。没有 keepalive、离线 license 或 CDM 默认网络请求。

`FrameworkCryptoConfig` 只包含系统会话句柄副本且禁止 insecure decoder components；不是内容密钥。HTTP/安装成功仍只 OPENED，系统 usable 才 OPENED_WITH_KEYS；pending/renewal 撤回可用状态。Media3 事件按 dispatcher 的引用数去重，失败只传固定类型，无 URL/body/vendor 状态字典或原始异常文本。

`YlProtectedCodecSelector` 为后续保护 renderer 专用，所有查询强制 secure，拒绝非 secure codec。视频另须精确硬件 metadata 证据；现有证据采集 API29+ 才能满足，API28 的 L1 会话门槛本身不保证这一 decoder 条件。包 minSdk24 不变。Media3 可以在 secure 查询为空时再查询非 secure decoder，因此仅关闭 decoder fallback 或请求 L1 不够。后续 3B2 还需核查实际初始化 decoder 与安全输出；本类的可用候选列表不能代替实际证据。

接口依据：[DrmSession 引用与状态](https://developer.android.com/reference/androidx/media3/exoplayer/drm/DrmSession)、[DrmSessionManager](https://developer.android.com/reference/androidx/media3/exoplayer/drm/DrmSessionManager)、[Media3 1.11 MediaCodecRenderer 的 secure fallback](https://github.com/androidx/media/blob/1.11.0/libraries/exoplayer/src/main/java/androidx/media3/exoplayer/mediacodec/MediaCodecRenderer.java)。本次仅以系统 fake 验证接口逻辑，没有真机解密、rotation/显示/HDCP 结论；生产 core/source factory/view/Pigeon 尚未接入这些内部类型。

## 10. Task 3B2：Android 原生保护输出与内部候选路线

原生 `yl_player_android/protected_video` 工厂使用安全 SurfaceView；创建时先 setSecure(true)，再添加到容器和注册 holder callback。四元组必须完全匹配已经 commit 的注册记录，且同一记录只能被一个 viewId 占用；未知、旧代际、候选未提交、重复占用均返回空黑视图。插件 detach 清空注册，原生 view 的销毁不释放 player；同一 Flutter engine 重新 attach（包括新的插件实例）时复用已注册工厂并绑定新的 registry；未知工厂占用相同类型时停止接入，不假装注册成功。

`YlProtectedPlayback` 是内部显式路由，连接 3B1 manager、Media3 DASH source factory、安全候选 PlaceholderSurface 和安全 inspection output。与旧输出共用 worker ACK、decoder lease 和会话协调器；受保护 route 不调用 Flutter texture、不进入 native/FFmpeg fallback。实际初始化 codec 必须属于已核查 secure 且 hardware 的候选；激活和恢复还需等待当前系统 keys usable，HTTP/Media3 READY 不能替代。声明 DRM 的已选视频不得转为 clear 成功。

候选独立准备且静音，安全/密钥失败走原有 lease 回滚；成功提交才激活 registry 身份并撤销前一呈现。首帧使用 engine 自己的输出身份，不能复用 texture generation。每次 holder attach/destroy 和 mount/unmount 都推进输出 revision；首帧必须同时匹配当前身份和成功的 worker attach ACK。先于 ACK 的帧暂存，旧 ACK/旧帧不显示。同一 Surface 重用时先同步停车到安全候选，记录 elapsedRealtime 边界，在 worker 等待 1ms 跨过时间戳精度后再绑定；只有 renderTimeMs 严格晚于边界的帧才属于当前输出，不以回调抵达时的 Surface 身份推断代次。后台或 view 消失时遮黑并停车到保留的安全候选 surface；恢复重新等待 decoder/key 证据后重绑仍存活的 holder。

SurfaceView holder 拥有其 Surface，插件不调用 release；holder 销毁立即撤销呈现资格，并同步等待 worker 的 Media3 停车确认才正常返回，dispose/retire 同样先解绑。此处是主线程异步策略的生命周期例外：不等待主线程协程续体或 registry mutex，排队 attach 在 worker 再次核验 volatile revision，避免销毁后重新借用 Surface。Media3 解绑失败/超时则终止该播放器、报告明确的原生错误；未获释放确认的私有资源保持 quarantine，不将错误返回视为 ACK，也不宣称失去响应的厂商渲染线程已安全释放。原生视图默认按显示尺寸/PAR 等比居中，使用黑色遮罩控制当前首帧；不读像素、不截图。裁切/Flutter overlay/旋转及实际物理保护仍需后续组合/真机验证。

Media3 最后一个 decoder 引用释放时，在该 owner 调用中同步撤销密钥请求、清除 challenge/session handle 并关闭 CDM；不把关闭操作排到即将退出的 playback Looper。

接口依据：[SurfaceHolder 销毁回调](https://developer.android.com/reference/android/view/SurfaceHolder.Callback#surfaceDestroyed(android.view.SurfaceHolder))、[Media3 首帧时间](https://developer.android.com/reference/androidx/media3/exoplayer/video/VideoRendererEventListener#onRenderedFirstFrame(java.lang.Object,long))，2026-09-28 核查。

这一步不提供 Dart descriptor/provider 或 Pigeon attach/key 消息，属于已经规划的 3B3；公开 adapter 仍拒绝 DRM 配置。内部 route 已与 core/source/事务连接，不等于已完成公共端到端受保护播放。API29 硬件 evidence、API28 系统 L1 和整包 API24 门槛保持。

## 11. Task 3B3：Android schema5 公共桥接（2026-09-28）

本节更新前文阶段性现状：Android 已消费 Widevine source，Apple 仍明确拒绝（待3C）。Android Dart/native 必须一起升级 schema5；旧 schema 在工厂创建前拒绝，不因新增字段丢弃 DRM。既有 enum 和工厂请求 codec tag 不变，Apple schema4 不变。

`AndroidDrmConfigMessage` 仅包含 cbcs 和许可证期限；URL、请求头和凭据留在 Dart `YlDrmLicenseEndpoint`。控制器通过可选 `YlPlatformDrmLicenseTransport` 注入既有 Task2 client；直接使用 SPI 的宿主须提供相同的 exchange delegate。取消 Future 在成功/失败结束时也完成，避免永久持有监听。许可证并发最多4个，每个存活会话最多4096个 exchangeId，重复请求不重复 POST，超限明确 resource.exhausted。

独立生成的 `AndroidDrmFlutterApi` 发送许可证 challenge/response、取消和受保护帧 ACK；`AndroidDrmHostApi` 提供按 loadRequestId 取消候选、attach/detach。exchange 身份包含 playerId/surfaceId/sessionId/generation、loadRequestId、epoch/requestId/exchangeId，响应须精确回传；原生只接受许可证错误白名单，不把 HTTP 失败推断为过期。双方释放/停止/替换会取消对应 exchange；候选失败保留当前会话，迟到字节不安装。桥接通知最多等待5秒。

加载回复提供独立的 `YlProtectedVideoSurface` 描述符，Dart 在会话回复与状态配对后才发布它。原生工厂只借用已提交的四元组；attach ACK 等待实际 worker 绑定，帧回调携带同一四元组/viewId/revision，首帧事件须与当前有效 ACK 配对后公开。dispose/unmount 仅解绑视图，不转移播放器所有权。

`YlPlayerView` 对 Android 保护描述符使用 `initExpensiveAndroidView` 显式 hybrid composition，依靠原生黑色遮罩与等比居中布局，不使用 texture、Opacity、FittedBox 或像素回读。当前保护视图仅接受默认 contain/center；其他 fit/alignment 明确报配置错误，不能悄悄忽略。字幕 overlay、旋转、裁切和外接物理保护仍需后续组合/授权验收。

系统 scheme 探测、桥接契约版本、API 门槛与实际保护证据分开：目前硬件 metadata 需要 API29，因此保护路线在 API24–28 明确拒绝（整包 minSdk24 不变）。评估报告 secureOutputUnknown/secureDecoderUnknown/protectionUnknown 和 keysRequireInspection；真正 load 仍须经过3B2的 secure output、实际初始化 decoder、L1 与 keys usable 检查。合同版本1不是全局 DRM 支持承诺，mock/普通 POST 测试也不证明物理解密播放成功。

attach 的成功、失败和超时同时核验当前 surface/viewId 与独立 attempt token；重试同一 viewId 也会撤销旧 attempt。替换、stop、unmount、dispose 立即撤销其发布资格，旧错误不终止新会话。当前失败在身份检查的同一同步步骤发布，不能在异步 caller catch 中无条件终止播放器。许可证白名单保留 `drm.license_redirect_rejected`，拒绝重定向与一般网络失败可明确区分。


## 12. Task 3C1：Apple 系统密钥所有权（内部）

Apple 没有可复用的系统密钥 owner，现有 AVPlayer 后端读取像素且保留 asset 路线。3C 分为本节系统密钥边界与后续3C2独立 AVPlayerLayer/候选事务/Pigeon 接入；3C 整体和公开 Apple DRM 准入仍未完成，schema4 保持，不能丢弃配置后转 clear。

`YlFairPlayKeySession` 每个候选独占 driver，主线程串行处理系统事件及响应安装。certificate 1..65536 bytes、contentId 1..8192 bytes、总期限1..60000ms；宿主给定内容标识用于生成SPC，不猜测 skd URL/provider规则。SPC最多1MiB、CKC最多4MiB；4个并发请求、每个系统会话最多4096个不同请求对象；重入/重复回调不重复交换，超限明确 resource.exhausted。内部 exchange 带 epoch/requestId，后续桥接还必须外包 player/session/surface/load 身份，不能仅靠这两个计数认证。

提交 CKC 不直接表示可用；仅当前对象、当前epoch、已经提交响应的系统 didSucceed 可确认。全部待处理请求确认后 isUsable 才为true，更新/rotation请求立即撤回；期限覆盖SPC生成、传输及系统确认。过期仅取系统明确的 receivedResponseWithExpiredLease；HTTP失败和SDK正常关闭生成的 expired-session report 均不代表许可证过期。系统自动 retry 永远false，网络POST重放预算由Task2独立负责。错误使用固定安全码与文案，不传播任意 NSError/vendor/URL/证书/SPC/CKC文本。

在 asset 加载任何键/元数据之前注册 AVContentKeyRecipient。停止/失败/释放先撤销归属，再取消deadline/传输、拒绝未完成请求、解绑delegate/recipient并expire。后台暂停终止该系统会话，恢复必须新建尚未加载的asset和新driver；已用asset的弱身份表阻止复用，不强持有全部历史asset。许可证回包及系统回调必须重新核对代际，旧事件不能恢复新会话。owner从非主线程释放时，将捕获的清理资源安排到主线程，不跨线程调用系统密钥对象。配置清理不声称能抹除SDK或Data所有内部副本。

后续3C2必须先从 AVPlayerLayer/AVPlayer 解绑过期recipient的播放，再调用suspend/close；恢复时创建新asset，禁止复用当前明文像素路径。isUsable 仅为系统响应处理证据，不是实际安全decoder、显示保护或HDCP证明；后续逐源策略与真实授权输出仍需独立验证。本阶段无离线持久密钥、证书自动获取、许可证会话报告上传或商业SDK。

依据：本地Xcode27 SDK AVContentKeySession.h，以及 Apple [系统响应成功回调](https://developer.apple.com/documentation/avfoundation/avcontentkeysessiondelegate/contentkeysession(_:contentkeyrequestdidsucceed:))、[密钥接收者注册](https://developer.apple.com/documentation/avfoundation/avcontentkeysession/addcontentkeyrecipient(_:))、[会话expire](https://developer.apple.com/documentation/avfoundation/avcontentkeysession/expire())，2026-09-28核查；包下限仍iOS15/macOS12。
