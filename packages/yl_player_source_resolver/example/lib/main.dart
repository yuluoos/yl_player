import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';

import 'demo_server.dart';

void main() => runApp(const MaterialApp(home: ResolverExample()));

class ResolverExample extends StatefulWidget {
  const ResolverExample({super.key});
  @override
  State<ResolverExample> createState() => _ResolverExampleState();
}

class _ResolverExampleState extends State<ResolverExample> {
  final _resolver = YlScriptResolver();
  YlPlayerController? _player;
  DemoServer? _server;
  YlScriptResolution? _pending;
  Future<void> _playerWork = Future.value();
  int _generation = 0;
  String _status = 'Preparing local synthetic fixture…';

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final server = await DemoServer.start();
      if (!mounted) {
        await server.close();
        return;
      }
      _server = server;
      final player = await YlPlayerController.create();
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _status = 'Ready · local synthetic video';
      });
    } on Object {
      if (mounted) setState(() => _status = 'Could not prepare the example.');
    }
  }

  // Serialize load/stop so an older load cannot overwrite a newer generation.
  Future<void> _withPlayer(Future<void> Function() action) {
    final next = _playerWork.then((_) => action());
    _playerWork = next.catchError((Object _) {});
    return next;
  }

  Future<void> _resolve({bool demonstrateCancellation = false}) async {
    final generation = ++_generation;
    final previous = _pending;
    _pending = null;
    await previous?.cancel();
    if (!mounted || generation != _generation) return;
    setState(() => _status = 'Resolving · generation $generation');
    final job = _pending = demonstrateCancellation
        ? _resolver.resolveSource('function main(){while(true){}}')
        : _resolver.resolve(
            YlScriptReference(
              scriptUri: _server!.scriptUri,
              parameters: 'channel=synthetic',
            ),
          );
    try {
      final resolved = await job.result;
      if (!mounted || generation != _generation) return;
      await _withPlayer(() async {
        if (!mounted || generation != _generation) return;
        final session = await _player!.load(resolved.toNetworkSource());
        if (!mounted || generation != _generation) return;
        await session.play();
        if (mounted && generation == _generation) {
          setState(() => _status = 'Playing · generation $generation');
        }
      });
    } on YlScriptException catch (error) {
      if (mounted && generation == _generation) {
        setState(() => _status = '${error.code} · ${error.message}');
      }
    } on Object {
      if (mounted && generation == _generation) {
        setState(() => _status = 'Playback could not start.');
      }
    } finally {
      if (identical(_pending, job)) _pending = null;
    }
  }

  Future<void> _cancel() async {
    final generation = ++_generation;
    final pending = _pending;
    _pending = null;
    await pending?.cancel();
    await _withPlayer(() async {
      if (!mounted || generation != _generation) return;
      await _player?.stop();
    });
    if (mounted && generation == _generation) {
      setState(
        () => _status = 'Cancelled and stopped · generation $generation',
      );
    }
  }

  @override
  void dispose() {
    ++_generation;
    unawaited(_resolver.dispose());
    unawaited(
      _withPlayer(() async {
        await _player?.dispose();
        await _server?.close();
      }),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Optional JS resolver')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          if (_player != null)
            Expanded(child: YlPlayerView(controller: _player!))
          else
            const Spacer(),
          Text(_status),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            children: [
              FilledButton(
                onPressed: _player == null ? null : () => _resolve(),
                child: const Text('Resolve & play / refresh'),
              ),
              OutlinedButton(
                onPressed: _player == null
                    ? null
                    : () => _resolve(demonstrateCancellation: true),
                child: const Text('Start cancellable work'),
              ),
              OutlinedButton(
                onPressed: _player == null ? null : _cancel,
                child: const Text('Cancel & stop'),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Synthetic local media only. Each new request replaces the previous generation. RTMP conversion is unsupported.',
            ),
          ),
        ],
      ),
    ),
  );
}
