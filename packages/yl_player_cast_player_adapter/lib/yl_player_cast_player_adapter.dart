/// yl_player 与可独立使用的 Cast 之间的可选桥接。
library;

import 'package:flutter/foundation.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_cast/yl_player_cast.dart';

/// 不创建、不销毁 [controller]，保留其会话身份和 AirPlay 状态语义。
final class YlPlayerCastAdapter implements YlCastLocalPlayer {
  const YlPlayerCastAdapter(this.controller);

  final YlPlayerController controller;

  @override
  YlPlayerState get state => controller.state;
  @override
  ValueListenable<YlAirPlayState> get airPlayState => controller.airPlayState;
  @override
  bool get supportsMediaDelivery => controller.supportsMediaDelivery;
  @override
  YlMediaDeliveryPreparation prepareMediaDelivery(YlMediaSource source) =>
      controller.prepareMediaDelivery(source);

  @override
  Future<YlPlayerCastSessionAdapter> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  }) async => YlPlayerCastSessionAdapter(
    await controller.load(source, options: options),
  );

  @override
  Future<void> stop() => controller.stop();
}

/// 保留原会话的过期检查；需要播放器完整会话 API 时访问 [session]。
final class YlPlayerCastSessionAdapter implements YlCastLocalSession {
  const YlPlayerCastSessionAdapter(this.session);

  final YlPlaybackSession session;

  @override
  YlPlaybackSessionId get id => session.id;
  @override
  Future<void> play() => session.play();
  @override
  Future<void> pause() => session.pause();
}
