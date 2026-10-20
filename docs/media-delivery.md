# 独立媒体交付与迁移

HLS 转封装和本机 HTTP 交付已经迁入可选插件 `yl_player_media_delivery`。
`yl_player_cast` 负责设备发现、投屏控制和调用交付接口。交付插件可以独立使用，无需创建播放器。

## 包边界

| 包 | 职责 | 依赖 |
|---|---|---|
| `yl_player_media_core` | FFmpeg 唯一副本、HTTP/RTMP/HLS 输入、取消、有界缓冲、交付服务契约 | Apple 系统框架与 Flutter 原生注册 |
| `yl_player_apple` | 播放、解码、渲染、系统 AirPlay、旧交付 API 适配 | core |
| `yl_player_media_delivery` | HLS 转封装、滚动存储、本机 HTTP 服务、准备与租约 | core、platform_interface |
| `yl_player_cast` | 投屏协议与设备控制；注入通用交付 provider 和最小本地播放器接口 | platform_interface |
| `yl_player_cast_player_adapter` | 将完整播放器接入 Cast 的 AirPlay、本地交接和旧交付 SPI | yl_player、cast、platform_interface |

播放器不依赖交付实现，交付实现也不依赖播放器。两个插件通过同一个 Flutter engine 内的可选原生服务注册表连接。FFmpeg 二进制、源代码和构建工具只由 core 持有。

## 现有 AirPlay 调用

需要自定义源转换的宿主增加依赖：

```yaml
dependencies:
  yl_player: ^0.3.0-dev.3
  yl_player_media_delivery: ^0.3.0-dev.3
```

完成依赖解析后重新构建宿主，Flutter 会注册原生交付服务。原有
`load(..., options: YlLoadOptions(airPlay: true))`、系统设备选择按钮和旧
`prepareMediaDelivery` 调用签名保持不变；此用法无需创建 Dart 交付实例。

兼容入口继续处理原有自定义 VOD 和 RTMP/RTMPS/HTTP-FLV 直播转换。
未安装交付插件时，自定义转换明确失败并返回 `airplay.delivery_unavailable`。
普通本地播放以及直接 HTTP/HLS AirPlay 无需增加此依赖。

## 无播放器的直播交付

新公共 provider 当前支持 RTMP、RTMPS 和 HTTP-FLV 直播；VOD 转换仍由播放器兼容入口调用同一原生实现。

```dart
import 'package:yl_player_media_delivery/yl_player_media_delivery.dart';

final delivery = await YlMediaDelivery.create();
final pending = delivery.prepareMediaDelivery(
  YlNetworkSource(
    Uri.parse('rtmps://live.example/app/channel'),
    intent: YlStreamIntent.live,
  ),
);
try {
  final lease = await pending.result;
  // 将 lease.uri、lease.contentType、lease.isLive 交给接收端。
  // 监听 lease.state；ready 表示可以拉取，不表示远端已经出帧。
  await lease.dispose();
} finally {
  await delivery.dispose();
}
```

投屏控制器可直接注入该实例：

```dart
final cast = YlCastController(
  mediaDelivery: delivery,
  providers: [dlnaProvider],
);
```

注入实例由调用方持有。应先释放投屏会话/控制器，再释放 delivery；控制器不会销毁外部注入的 provider。保留的旧播放器 SPI 可用于兼容接入。

需要本地播放交接或 AirPlay 时，显式增加 `yl_player_cast_player_adapter`：

```dart
import 'package:yl_player_cast_player_adapter/yl_player_cast_player_adapter.dart';

final cast = YlCastController(
  providers: [dlnaProvider],
  player: YlPlayerCastAdapter(player),
  mediaDelivery: delivery,
);
// 旧 handoff.session: local 改为：
final handoff = YlCastHandoff(
  session: YlPlayerCastSessionAdapter(local),
  source: source,
);
```

`loadAirPlay` 和 `returnToLocal` 现在返回 `YlCastLocalSession`，提供身份、播放和暂停操作。
使用上述适配器时，可通过 `YlPlayerCastSessionAdapter.session` 访问完整播放器会话。
适配器不创建或销毁播放器。纯 DLNA 可只依赖 Cast；Apple 自定义直播还需独立 delivery，但无需完整播放器。

## 资源和平台语义

- 每个 provider 独立创建 owner，不依赖隐藏播放器；不同 owner 和 Flutter engine 相互隔离。
- 准入请求至多一个执行、一个最新排队候选。拒绝新请求保留旧准备和租约，合法新请求取消旧准备，准备成功后才替换旧租约。
- 等待中可以调用 `pending.cancel()`；准备完成后取消不会释放已经返回的租约。租约或 provider 的 `dispose()` 会释放对应生产者、临时文件和服务。
- 支持 iOS 15+、macOS 12+；没有新增 Android 转封装。非 Apple 平台或原生插件不可用时，独立 `create()` 返回 `policy.unsupported`。
- 继续使用 H.264/AAC 压缩样本转封装，不做视频转码。RTMPS 保持上游 TLS，输出 HLS 通过局域网 HTTP 提供。
- 保持原有格式、时间戳、内存、磁盘、请求策略与网络权限限制，详见 [AirPlay 文档](airplay.md)。手机与接收端仍需能够互相访问本机服务。
- 播放器与独立交付共用原生请求头准入规则：允许水平 Tab，拒绝 CR/LF、其他 C0/DEL、保留头、大小写重复及未明确分类的敏感普通头。

macOS 嵌入宿主主动关闭 engine 时，需要先在主线程调用该 engine 发布的
`YlPlayerMediaDeliveryPlugin.shutdown()`，再调用 `engine.shutDownEngine()`。
该入口释放独立交付 owner；macOS 没有插件 detach 回调，不能只等待插件析构。
宿主仍应先停止/销毁自己持有的播放器等其他资源。完整代码及双引擎回归入口见
[交付插件说明](../packages/yl_player_media_delivery/README.md)。

## 验证范围

原生模块编译、Flutter 通道、无播放器交付、真实 HLS 拉取与示例构建可以验证代码和资源生命周期。它们不能代替实体 AirPlay/DLNA 接收端、CarPlay 车机和长时间直播验收。
