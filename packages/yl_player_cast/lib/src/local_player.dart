import 'package:flutter/foundation.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

/// 调用方持有的本地播放器能力；纯 DLNA 使用者无需提供此接口。
///
/// 实现必须保持会话身份校验：替换或停止后，旧会话不能控制新媒体。
/// Cast 只停止自己创建且仍为当前身份的 AirPlay 会话，不销毁播放器。
abstract interface class YlCastLocalPlayer {
  YlPlayerState get state;
  ValueListenable<YlAirPlayState> get airPlayState;

  /// 仅用于兼容播放器自带的交付能力，独立 mediaDelivery 注入优先。
  bool get supportsMediaDelivery;
  YlMediaDeliveryPreparation prepareMediaDelivery(YlMediaSource source);

  Future<YlCastLocalSession> load(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  });
  Future<void> stop();
}

/// 本地交接所需的最小会话操作；操作必须拒绝已被替换的会话。
abstract interface class YlCastLocalSession {
  YlPlaybackSessionId get id;
  Future<void> play();
  Future<void> pause();
}
