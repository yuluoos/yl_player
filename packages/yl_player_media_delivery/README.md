# yl_player_media_delivery

可选、独立的 Apple 媒体交付插件。RTMP、RTMPS 或 HTTP-FLV 自定义直播经 H.264/AAC 转封装生成 HLS/fMP4，本机 HTTP 服务供接收端拉取。支持 iOS 15+、macOS 12+，不创建播放器或隐藏 AVPlayer，不转码。仅依赖通用平台接口及原生输入 core，不依赖 `yl_player`、`yl_player_apple` 或投屏包。

```dart
import 'package:yl_player_media_delivery/yl_player_media_delivery.dart';

final delivery = await YlMediaDelivery.create();
final preparation = delivery.prepareMediaDelivery(
  YlNetworkSource(
    Uri.parse('rtmps://live.example/app/stream'),
    intent: YlStreamIntent.live,
  ),
);
try {
  final lease = await preparation.result;
  // 使用 lease.uri / contentType / isLive，并监听 lease.state。
  // ready 仅表示资源可拉取，不表示接收端已经出帧。
  await lease.dispose();
} finally {
  await delivery.dispose();
}
```

在等待期间可调用 `preparation.cancel()`。取消已完成的准备不会释放其租约。每个 provider 至多一个执行准入、一个最新排队候选、一个生产准备和一个已接受租约；拒绝新准入保留既有资源，合法新请求取消旧准备，准备成功才替换旧租约。不同 provider 的生命周期相互隔离。停止或销毁后接收端不能继续依赖本机服务。

非 Apple 平台或未注册原生插件的 `create()` 明确返回 `policy.unsupported`。错误通过 `YlPlayerException` 提供稳定错误码及脱敏文案，不输出 URL、凭据或上游错误原文。自定义直播只接受默认网络策略，格式为 `automatic` / `flv`，不支持非零起始位置、自定义缓冲和画面尺寸/码率约束；转封装不执行解码，解码器偏好不影响此路径。RTMPS 保留上游 TLS；本机 HTTP 交付需可信局域网及宿主相应网络权限。

与投屏集成时将实例传入 `YlCastController(mediaDelivery: delivery, providers: [...])`，无需播放器；控制器销毁后由调用方销毁 delivery。旧 Apple 播放器交付 API 和自定义 AirPlay 转换也需要宿主显式添加本插件。普通本地播放及 HTTP/HLS 直接 AirPlay 不需要本包。

包边界、可选依赖配置与旧 API 迁移见[中文迁移指南](../../docs/media-delivery.md)。

macOS 宿主主动销毁 FlutterEngine 时，必须在主线程、`shutDownEngine()` 之前关闭该引擎发布的交付插件。macOS 的 `FlutterPlugin` 没有 detach 回调，引擎关闭后仍可能持有 published plugin；仅依赖 `deinit` 无法及时停止直播和 HTTP 服务。

```swift
import FlutterMacOS
import yl_player_media_delivery

func stopFlutterEngine(_ engine: FlutterEngine) {
  let delivery = engine.valuePublished(
    byPlugin: "YlPlayerMediaDeliveryPlugin"
  ) as? YlPlayerMediaDeliveryPlugin
  delivery?.shutdown()
  engine.shutDownEngine()
}
```

`shutdown()` 会关闭该插件的全部交付 owner，移除方法通道和该引擎的交付 registry；重复调用安全，不影响其他引擎。使用自定义注册 key 时，应以相同 key 查询 published plugin。iOS 继续通过 `detachFromEngine` 自动清理。普通 Dart provider 生命周期仍应调用 `dispose()`。

真实 macOS 双引擎回归可运行 `python3 tool/media_delivery/run_macos_shutdown_test.py`（在仓库根目录执行；需要 Flutter、Xcode、已构建的 FFmpeg bridge 和可用局域网 IPv4）。测试不创建播放器，使用持续 HTTP-FLV 输入和实际 Dart 通道，验证显式关闭后 HTTP 不可访问、方法通道和 registry 被移除、重复调用安全及另一引擎继续交付。
