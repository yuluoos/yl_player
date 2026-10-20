import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_cast/yl_player_cast.dart';
import 'package:yl_player_cast_example/cast_status.dart';

void main() {
  testWidgets('discovery distinguishes scanning, failure and stopped', (
    tester,
  ) async {
    Future<void> show(YlCastDiscoveryState state) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CastDiscoveryStatus(states: {'dlna': state})),
      ),
    );
    await show(const YlCastDiscoveryState(scanning: true));
    expect(find.text('dlna：正在搜索设备…'), findsOneWidget);
    await show(
      const YlCastDiscoveryState(failureCode: 'cast.discovery_unavailable'),
    );
    expect(
      find.textContaining('搜索失败（cast.discovery_unavailable）'),
      findsOneWidget,
    );
    expect(find.textContaining('正在搜索'), findsNothing);
    await show(const YlCastDiscoveryState());
    expect(find.text('dlna：搜索已停止'), findsOneWidget);
  });

  testWidgets('remote buttons respect capabilities and route conflicts', (
    tester,
  ) async {
    const device = YlCastDevice(id: '1', providerId: 'dlna', name: 'TV');
    final actions = <CastControlAction>[];
    Future<void> show(YlCastSnapshot state) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CastRemoteControls(
            state: state,
            busy: false,
            canReturnToLocal: true,
            onAction: actions.add,
          ),
        ),
      ),
    );
    bool enabled(String label) =>
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, label))
            .onPressed !=
        null;
    await show(const YlCastSnapshot());
    expect(enabled('播放'), isFalse);
    expect(enabled('停止'), isFalse);
    await show(
      const YlCastSnapshot(device: device, capabilities: YlCastCapabilities()),
    );
    expect(enabled('播放'), isTrue);
    expect(enabled('暂停'), isFalse);
    expect(enabled('断开并继续播放'), isFalse);
    await show(
      const YlCastSnapshot(
        device: device,
        capabilities: YlCastCapabilities(pause: true),
        canDetachKeepingPlayback: true,
      ),
    );
    await tester.tap(find.text('暂停'));
    expect(actions, [CastControlAction.pause]);
    expect(enabled('断开并继续播放'), isTrue);
    await show(
      const YlCastSnapshot(
        device: device,
        airPlayActive: true,
        capabilities: YlCastCapabilities(pause: true),
      ),
    );
    expect(enabled('播放'), isFalse);
    expect(enabled('暂停'), isFalse);
    expect(enabled('返回本地'), isFalse);
    expect(enabled('停止'), isTrue);
  });
}
