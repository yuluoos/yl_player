import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_cast/yl_player_cast.dart';

import 'cast_status.dart';

void main() => runApp(const MaterialApp(home: CastExample()));

class CastExample extends StatefulWidget {
  const CastExample({super.key});
  @override
  State<CastExample> createState() => _CastExampleState();
}

class _CastExampleState extends State<CastExample> {
  final _url = TextEditingController();
  YlPlayerController? _player;
  YlCastController? _cast;
  YlPlaybackSession? _localSession;
  YlMediaSource? _localSource;
  String _message = '正在初始化播放器';
  bool _busy = false;
  bool _live = false;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    try {
      final player = await YlPlayerController.create();
      if (!mounted) {
        await player.dispose();
        return;
      }
      _player = player;
      // 仅填入通过真机验收、支持 HLS/fMP4 的设备 UUID。
      _cast = YlCastController(
        providers: [YlDlnaProvider(verifiedHlsFmp4DeviceIds: const {})],
        player: player,
      );
      setState(() => _message = '输入媒体地址，然后搜索局域网设备');
    } on Object {
      if (mounted) setState(() => _message = '播放器初始化失败');
    }
  }

  YlMediaSource _source() => YlNetworkSource(
    Uri.parse(_url.text.trim()),
    intent: _live ? YlStreamIntent.live : YlStreamIntent.automatic,
  );

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) setState(() => _message = '命令已确认，请检查接收端画面');
    } on YlCastException catch (e) {
      if (mounted) setState(() => _message = '投屏失败：${e.code}');
    } on YlPlayerException catch (e) {
      if (mounted) setState(() => _message = '播放失败：${e.failure.code}');
    } on Object {
      if (mounted) setState(() => _message = '操作失败，请检查地址、设备和网络权限');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    final cast = _cast;
    final player = _player;
    unawaited(() async {
      try {
        await cast?.dispose();
      } finally {
        await player?.dispose();
      }
    }());
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cast = _cast;
    final player = _player;
    return Scaffold(
      appBar: AppBar(title: const Text('DLNA / AirPlay 投屏')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: '媒体地址',
              hintText: 'https://…/video.mp4 或 rtmps://…',
            ),
          ),
          SwitchListTile(
            title: const Text('直播'),
            value: _live,
            onChanged: _busy ? null : (value) => setState(() => _live = value),
          ),
          Text(_message),
          if (cast != null && player != null) ...[
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: _busy ? null : () => _run(cast.startDiscovery),
                  child: const Text('搜索设备'),
                ),
                TextButton(
                  onPressed: () => _run(cast.stopDiscovery),
                  child: const Text('停止搜索'),
                ),
                TextButton(
                  onPressed: () async {
                    await cast.cancelPending();
                    if (mounted) setState(() => _message = '已请求取消');
                  },
                  child: const Text('取消连接'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final source = _source();
                          _localSession = await player.load(
                            source,
                            options: const YlLoadOptions(autoplay: true),
                          );
                          _localSource = source;
                        }),
                  child: const Text('本地播放'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          final source = _source();
                          _localSession = await cast.loadAirPlay(
                            source,
                            options: const YlLoadOptions(autoplay: true),
                          );
                          _localSource = source;
                        }),
                  child: const Text('准备 AirPlay'),
                ),
                YlAirPlayButton(
                  controller: player,
                  fallback: const Text('AirPlay 未就绪'),
                ),
              ],
            ),
            SizedBox(height: 220, child: YlPlayerView(controller: player)),
            ValueListenableBuilder<Map<String, YlCastDiscoveryState>>(
              valueListenable: cast.discovery,
              builder: (context, states, _) =>
                  CastDiscoveryStatus(states: states),
            ),
            ValueListenableBuilder<List<YlCastDevice>>(
              valueListenable: cast.devices,
              builder: (context, devices, _) => Column(
                children: [
                  if (devices.isEmpty) const ListTile(title: Text('尚未发现设备')),
                  for (final device in devices)
                    ListTile(
                      title: Text(device.name),
                      subtitle: Text(device.id),
                      trailing: FilledButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                await cast.cast(device, _source());
                              }),
                        child: const Text('投屏'),
                      ),
                      onTap: _localSession == null || _busy
                          ? null
                          : () => _run(() async {
                              await cast.cast(
                                device,
                                _localSource!,
                                handoff: YlCastHandoff(
                                  session: _localSession!,
                                  source: _localSource!,
                                  options: const YlLoadOptions(autoplay: true),
                                ),
                              );
                            }),
                    ),
                ],
              ),
            ),
            const Text('点击设备行可将当前本地会话转到该设备；“投屏”使用输入框地址。'),
            ValueListenableBuilder<YlCastSnapshot>(
              valueListenable: cast.state,
              builder: (context, state, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '远端：${state.device?.name ?? "未连接"} · ${state.playback.status.name}',
                  ),
                  if (state.failureCode != null) Text(state.failureCode!),
                  if (state.routeConflict) const Text('请先在系统选择器中断开 AirPlay'),
                  CastRemoteControls(
                    state: state,
                    busy: _busy,
                    canReturnToLocal:
                        _localSession != null &&
                        player.state.sessionId == _localSession!.id,
                    onAction: (action) => unawaited(
                      _run(() async {
                        switch (action) {
                          case CastControlAction.play:
                            await cast.play();
                          case CastControlAction.pause:
                            await cast.pause();
                          case CastControlAction.stop:
                            await cast.stop();
                          case CastControlAction.detach:
                            await cast.disconnect(keepPlaying: true);
                          case CastControlAction.returnLocal:
                            _localSession = await cast.returnToLocal();
                        }
                      }),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
