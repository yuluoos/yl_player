# yl_player_cast_player_adapter

可选的 `yl_player` 播放器接入包。纯 DLNA 只需 `yl_player_cast`；本包供本地会话交接、AirPlay 路由监听及播放器兼容交付使用，会随 `yl_player` 安装其原生平台依赖。

```dart
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_cast/yl_player_cast.dart';
import 'package:yl_player_cast_player_adapter/yl_player_cast_player_adapter.dart';

final player = await YlPlayerController.create();
final cast = YlCastController(
  providers: [YlDlnaProvider()],
  player: YlPlayerCastAdapter(player),
);
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
await player.dispose();
```

迁移时将旧 `player: player` 改为 `player: YlPlayerCastAdapter(player)`，`handoff.session` 包装为 `YlPlayerCastSessionAdapter(local)`。Cast 的 `loadAirPlay` / `returnToLocal` 返回 `YlCastLocalSession`，可播放、暂停和读取身份；使用本适配器的结果可转为 `YlPlayerCastSessionAdapter` 并通过 `.session` 获取完整播放器会话。`YlPlayerCastAdapter.load()` 也可直接返回适配后的会话。

适配器不持有资源所有权，不创建或销毁播放器。旧会话命令仍由真实播放器校验，切源或停止后不能控制新媒体。AirPlay 状态直接观察原播放器；系统选择器仍使用 `YlAirPlayButton(controller: player)`。

独立直播交付优先通过 Cast 的 `mediaDelivery` 注入。兼容的播放器交付能力仅在未注入独立 provider 时使用。

测试：`flutter test packages/yl_player_cast_player_adapter/test`。完整接入示例位于 `../yl_player_cast/example`。
