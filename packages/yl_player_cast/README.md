# yl_player_cast

可独立使用的投屏包，提供 DLNA 设备发现、远端播放控制和 AirPlay 统一入口。核心只依赖 Flutter、XML 和平台接口，不传递安装 `yl_player`、Apple 播放插件或 FFmpeg。需要本地播放器交接或 AirPlay 时，再添加可选 `yl_player_cast_player_adapter`。Google Cast 不在本包范围内。

## 支持范围

| 功能 | Android 24+ | iOS 15+ / macOS 12+ |
| --- | --- | --- |
| SSDP 发现 DLNA MediaRenderer | 支持 | 支持，需要宿主网络权限 |
| HTTP(S) MP4 / HLS 直连 | 依赖接收端声明的格式能力 | 同左 |
| 播放、暂停、停止、进度、音量、静音 | 按设备 SCPD 能力开放 | 同左 |
| RTMP / RTMPS / HTTP-FLV 转 HLS 交付 | 不支持 | 注入可选 delivery 的 H.264/AAC 转封装 |
| AirPlay 系统选择器 | 不支持 | 复用既有 `YlAirPlayButton` |

这不是屏幕镜像协议实现。Web、Windows、Linux 不在支持范围内。DLNA 设备报告的协议能力不保证解码、网络可达或实际出帧；命令确认与接收端实际画面分开判断。

## 最小接入

```dart
import 'package:yl_player_cast/yl_player_cast.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

final cast = YlCastController(
  providers: [YlDlnaProvider()],
);
await cast.startDiscovery();
// 通过 cast.devices 监听列表，并让用户选择设备。
await cast.cast(
  selectedDevice,
  YlNetworkSource(Uri.parse('https://media.example/video.mp4')),
);
await cast.pause();
await cast.play();
await cast.seek(const Duration(minutes: 2));
await cast.setVolume(0.5); // 0...1；映射到设备声明的范围
await cast.setMuted(false);
await cast.stop();
await cast.dispose();
```

`cast.discovery` 按 provider ID 提供 `YlCastDiscoveryState`，包含 `scanning` 和脱敏的 `failureCode`，可区分正在扫描、停止和发现失败。错误可在 `startDiscovery()` 返回后异步发生，界面应持续监听；重试时清除旧错误。

`cast.state` 提供设备、接收端播放状态、连接状态、AirPlay 冲突、失败码及当前会话的 `capabilities`。未连接时能力为 `null`；暂停、跳转、音量、静音按钮应按能力开放。能力已包含托管直播禁止 seek、托管媒体禁止脱离控制继续播放等限制。未知进度、时长、音量保持 `null`，不伪造测量结果。设备能力来自设备描述、SCPD 和 ConnectionManager；没有相应操作时返回稳定的 `cast.*` 错误。

直连只发送媒体 URL 和元数据，不会转发 `YlHttpRequest` 的 headers/credentials，也不能承诺在电视上执行应用的 managed HTTP 策略；这些要求会明确拒绝。无扩展名地址可显式提供 `contentType`，仍必须通过设备能力检查。设备对 HLS 仅声明 `*` 不算已验证支持。

## 自定义直播

Apple 路径需显式添加 `yl_player_media_delivery`，再通过 `mediaDelivery` 注入。`yl_player_cast` 不自动安装交付实现。路径为 RTMP/RTMPS/HTTP-FLV → 独立原生 H.264/AAC 转封装 → 本机 HLS/fMP4 HTTP 服务 → DLNA 接收端拉取。不启动隐藏 AVPlayer，不进行转码。RTMPS 上游仍使用 TLS；局域网媒体服务为 HTTP，需要可信局域网。

独立直播交付目前仅接受默认网络策略，不接受 managed 策略；无法兑现的超时、重试或缓冲约束会明确拒绝。格式只有 `automatic` / `flv` 可进入这条路径，扩展名不会覆盖明确指定的其他格式。

替换直播准备先通过原生参数准入；被拒绝的请求不会取消已经通过准入的准备或已接受租约。准入阶段最多保留一个执行请求和一个最新排队请求；取消或销毁后的迟到准入结果不会启动生产器。

HLS MIME 声明不能证明设备支持 fMP4 分片。必须先在目标设备上验收，然后显式登记其发现列表中的 UUID：

```dart
import 'package:yl_player_media_delivery/yl_player_media_delivery.dart';

final delivery = await YlMediaDelivery.create();
final provider = YlDlnaProvider(
  verifiedHlsFmp4DeviceIds: {'uuid:实际验收过的设备标识'},
);
final cast = YlCastController(providers: [provider], mediaDelivery: delivery);
await cast.cast(
  selectedDevice,
  YlNetworkSource(
    Uri.parse('rtmps://live.example/app/stream'),
    intent: YlStreamIntent.live,
  ),
);
```

独立交付不需要创建播放器。`mediaDelivery` 优先于兼容的 `player.prepareMediaDelivery` 路径；调用方依次 `await cast.dispose()`、`await delivery.dispose()`，控制器不会销毁注入的 provider。`player` 参数接受 `YlCastLocalPlayer`，仅在本地交接、路由冲突监听或 AirPlay 功能需要时传入可选适配器。

还需要设备声明 HLS MIME；登记列表不会绕过设备能力检查。不支持 HLS/fMP4 的电视不能使用此转换路径。Android 会在准备资源前返回 `cast.delivery_unavailable`。不支持直播非零初始位置和 seek。

直播租约随停止、销毁或生产失败释放。托管媒体的 `canDetachKeepingPlayback` 为 `false`；调用 `disconnect(keepPlaying: true)` 返回 `cast.detach_unsupported` 并保留当前会话。应用退出后不能承诺电视继续拉取本机直播。普通直连 URL 可断开控制并保持接收端播放。

脚本解析结果沿用 `yl_player_source_resolver` 的 `YlMediaSource`，直接交给 `cast.assess(device, source)` 和 `cast.cast(device, source)`。解析器不依赖投屏包，解析成功也不等于接收端兼容。

## 本地交接与 AirPlay

应用显式添加 `yl_player` 和 `yl_player_cast_player_adapter`，并按下面方式桥接：

```dart
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_cast/yl_player_cast.dart';
import 'package:yl_player_cast_player_adapter/yl_player_cast_player_adapter.dart';

final player = await YlPlayerController.create();
final adapter = YlPlayerCastAdapter(player);
final cast = YlCastController(providers: [YlDlnaProvider()], player: adapter);
final local = await player.load(source);
await cast.cast(
  selectedDevice,
  source,
  handoff: YlCastHandoff(
    session: YlPlayerCastSessionAdapter(local),
    source: source,
  ),
);
await cast.returnToLocal();
await cast.dispose();
await player.dispose(); // 仍由调用方销毁播放器
```

迁移：原 `player: player` 改为 `player: YlPlayerCastAdapter(player)`，原交接会话改用 `YlPlayerCastSessionAdapter(localSession)`。`loadAirPlay()` 和 `returnToLocal()` 返回最小接口 `YlCastLocalSession`（身份、播放、暂停）；通过上述适配器创建的结果可转为 `YlPlayerCastSessionAdapter`，访问其 `.session` 获取原完整 `YlPlaybackSession`。也可直接使用 `adapter.load()` 获得适配后的会话。自有播放器可实现 `YlCastLocalPlayer` / `YlCastLocalSession`，无需依赖本适配包。

显式传入 `YlCastHandoff(session: YlPlayerCastSessionAdapter(localSession), source: source, options: originalOptions)` 可保存本地位置和播放意图。只有接收端接受媒体后才暂停本地；加载失败保留本地播放。`returnToLocal()` 停止远端并重新打开原始源，使用接收端已观察到的位置或交接时的本地位置。直播重新进入直播位置。

停止远端期间若本地已切源、启用 AirPlay，或调用方取消/销毁控制器，返回操作会拒绝，避免覆盖新的本地会话。取消后才完成的本地恢复仅在身份仍匹配时停止。

一个控制器同时持有一个 DLNA 会话。切换设备/源前先 `stop()` 或 `disconnect()`，避免旧 Stop 影响新会话。`cancelPending()` 可取消尚未完成的准备；迟到回复会清理资源，不会发布新会话。

```dart
await cast.loadAirPlay(source, options: const YlLoadOptions(autoplay: true));
// 在界面放置 YlAirPlayButton(controller: player)，由用户选择系统设备。
```

原 `player.load(source, options: YlLoadOptions(airPlay: true))` 接口保持兼容。AirPlay 激活时启动 DLNA 会返回 `cast.route_conflict`；请先在系统选择器中断开 AirPlay。DLNA 活跃时，统一 AirPlay 加载入口也会拒绝。外部旧接口激活 AirPlay 时仅报告冲突，不擅自停止电视。`stop()`/`dispose()` 清理由本控制器创建且仍匹配当前身份的 AirPlay 会话，不销毁调用方播放器或外部替换的会话。

## 宿主配置

- Android：插件合并 INTERNET、Wi-Fi 状态和组播权限，扫描及持有会话期间引用计数组播锁。宿主需按自己的网络策略允许 DLNA 局域网 HTTP；示例为演示启用 cleartext。组播受路由器、AP 隔离及系统节电影响。
- iOS：添加中文 `NSLocalNetworkUsageDescription`。SSDP 组播需开发者账号获得 `com.apple.developer.networking.multicast` entitlement 并配置匹配 provisioning profile；插件和示例无法代替 Apple 授权。权限不满足时不能承诺发现成功。
- macOS sandbox：启用 `com.apple.security.network.client` 与 `com.apple.security.network.server`，并提供 `NSLocalNetworkUsageDescription`。示例已配置。
- 真机必须能访问相同局域网，VPN/热点/接口切换可能使已有交付 URL 失效，此时停止并重新投屏。

设备 XML 和网络响应按不可信输入处理：设备数量、响应大小、XML 深度、请求时限与轮询退避都有上限；禁用 DTD、自定义实体和 HTTP 自动重定向；设备控制请求不携带媒体凭据。

当前发现使用 IPv4 SSDP M-SEARCH，设备缓存按 max-age 过期；同一 UUID 的 LOCATION 变化会重新获取描述，旧请求的迟到响应不会覆盖新端点。最多缓存 128 个设备、并行 8 个描述作业。SOAP 使用 UTF-8 字节长度设置 Content-Length，兼容不接受 chunked 请求的接收端。会话状态采用有界轮询，暂未使用 GENA 订阅。异步发现错误推荐通过 `cast.discovery` 监听；保留 `YlDlnaProvider.discoveryError` 便于直接使用 provider。

## 示例与验证

独立示例位于 `example/`，包含搜索、直连投屏、本地交接、取消、远端控制、返回本地和 AirPlay 系统按钮。运行前完成上述宿主权限及 Apple 原生二进制依赖准备。示例默认没有登记 HLS/fMP4 设备，防止未经验证的自定义直播转换。

```sh
flutter test packages/yl_player_cast/test
flutter test packages/yl_player_cast_player_adapter/test
python3 packages/yl_player_cast/tool/check_standalone_dependencies.py
cd packages/yl_player_cast/example
flutter run
```

回环 UDP/HTTP 测试覆盖协议行为，原生构建和模拟器回归覆盖软件集成；真实电视发现、解码、第一帧、后台行为和网络切换仍需分别做真机验收。
