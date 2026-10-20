import 'package:flutter/foundation.dart';
import '../model/failure.dart';
import '../options/load_options.dart';
import '../source/media_source.dart';

/// 生命周期与接收端播放状态无关；ready 仅代表媒体可以被拉取。
enum YlMediaDeliveryStatus { ready, failed, closed }

@immutable
final class YlMediaDeliveryState {
  const YlMediaDeliveryState({required this.status, this.failure});
  final YlMediaDeliveryStatus status;
  final YlFailure? failure;
}

/// 会话必须持有租约；释放租约后接收端不能继续依赖本机媒体服务。
abstract interface class YlMediaDeliveryLease {
  Uri get uri;
  String get contentType;
  bool get isLive;
  ValueListenable<YlMediaDeliveryState> get state;
  Future<void> dispose();
}

/// 同步获得取消句柄。取消已完成的准备操作不会释放其租约。
abstract interface class YlMediaDeliveryPreparation {
  Future<YlMediaDeliveryLease> get result;
  Future<void> cancel();
}

/// 可选 SPI。每播放器最多持有一个准备操作和一个已交付租约。
/// 新资源准备失败保留旧租约；准备成功替换并关闭旧租约。
abstract interface class YlMediaDeliveryPlatformPlayer {
  YlMediaDeliveryPreparation prepareMediaDelivery(
    YlMediaSource source, {
    YlLoadOptions options = const YlLoadOptions(),
  });
}
