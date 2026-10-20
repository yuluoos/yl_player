import 'package:flutter/material.dart';
import 'package:yl_player_cast/yl_player_cast.dart';

class CastDiscoveryStatus extends StatelessWidget {
  const CastDiscoveryStatus({required this.states, super.key});
  final Map<String, YlCastDiscoveryState> states;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final entry in states.entries)
        Text(
          '${entry.key}：${entry.value.failureCode != null
              ? "搜索失败（${entry.value.failureCode}），请检查网络权限后重试"
              : entry.value.scanning
              ? "正在搜索设备…"
              : "搜索已停止"}',
        ),
    ],
  );
}

enum CastControlAction { play, pause, stop, detach, returnLocal }

class CastRemoteControls extends StatelessWidget {
  const CastRemoteControls({
    required this.state,
    required this.busy,
    required this.canReturnToLocal,
    required this.onAction,
    super.key,
  });
  final YlCastSnapshot state;
  final bool busy;
  final bool canReturnToLocal;
  final ValueChanged<CastControlAction> onAction;

  @override
  Widget build(BuildContext context) {
    final connected = !busy && state.device != null;
    final controllable = connected && !state.routeConflict;
    Widget button(String label, CastControlAction action, bool enabled) =>
        TextButton(
          onPressed: enabled ? () => onAction(action) : null,
          child: Text(label),
        );
    return Wrap(
      spacing: 8,
      children: [
        button('播放', CastControlAction.play, controllable),
        button(
          '暂停',
          CastControlAction.pause,
          controllable && (state.capabilities?.pause ?? false),
        ),
        button('停止', CastControlAction.stop, connected),
        button(
          '断开并继续播放',
          CastControlAction.detach,
          connected && state.canDetachKeepingPlayback,
        ),
        button(
          '返回本地',
          CastControlAction.returnLocal,
          controllable && canReturnToLocal,
        ),
      ],
    );
  }
}
