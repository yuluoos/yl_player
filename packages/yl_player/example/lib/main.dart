import 'dart:async';
import 'package:flutter/material.dart';
import 'package:yl_player/yl_player.dart';

void main() => runApp(const PlayerExampleApp());

typedef PlayerCreator = Future<YlPlayerController> Function();

class PlayerExampleApp extends StatelessWidget {
  const PlayerExampleApp({
    this.createPlayer = YlPlayerController.create,
    super.key,
  });

  final PlayerCreator createPlayer;

  @override
  Widget build(BuildContext context) =>
      MaterialApp(home: PlayerExamplePage(createPlayer: createPlayer));
}

class PlayerExamplePage extends StatefulWidget {
  const PlayerExamplePage({required this.createPlayer, super.key});

  final PlayerCreator createPlayer;

  @override
  State<PlayerExamplePage> createState() => _PlayerExamplePageState();
}

class _PlayerExamplePageState extends State<PlayerExamplePage> {
  final _url = TextEditingController();
  late final Future<YlPlayerController> _creation;
  YlPlaybackSession? _session;
  bool _live = false;
  String? _message;
  int _operationGeneration = 0;
  @override
  void initState() {
    super.initState();
    _creation = widget.createPlayer();
  }

  @override
  void dispose() {
    _operationGeneration++;
    _session = null;
    unawaited(_disposePlayer());
    _url.dispose();
    super.dispose();
  }

  Future<void> _disposePlayer() async {
    try {
      final player = await _creation;
      await player.dispose();
    } catch (_) {
      // Creation and cleanup are already reflected by removing this widget.
    }
  }

  bool _isCurrent(int generation, [YlPlaybackSession? session]) =>
      mounted &&
      generation == _operationGeneration &&
      (session == null || identical(_session, session));

  String _safeMessage(Object error, String fallback) =>
      error is YlPlayerException ? error.failure.message : fallback;

  Future<void> _load(YlPlayerController player) async {
    final generation = ++_operationGeneration;
    setState(() => _message = 'Loading');
    try {
      final session = await player.load(
        YlNetworkSource(
          Uri.parse(_url.text),
          intent: _live ? YlStreamIntent.live : YlStreamIntent.onDemand,
        ),
      );
      if (!_isCurrent(generation)) return;
      _session = session;
      await session.play();
      if (!_isCurrent(generation, session)) return;
      await session.ready;
      if (!_isCurrent(generation, session)) return;
      setState(() => _message = 'Ready');
      unawaited(_observeFirstFrame(session, generation));
    } catch (error) {
      if (_isCurrent(generation)) {
        setState(() => _message = _safeMessage(error, 'Could not load media.'));
      }
    }
  }

  Future<void> _observeFirstFrame(
    YlPlaybackSession session,
    int generation,
  ) async {
    try {
      await session.firstFrame;
      if (_isCurrent(generation, session)) {
        setState(() => _message = 'First frame displayed');
      }
    } catch (error) {
      if (_isCurrent(generation, session)) {
        setState(
          () => _message = _safeMessage(error, 'Could not display video.'),
        );
      }
    }
  }

  Future<void> _pause() async {
    final session = _session;
    if (session == null) return;
    final generation = _operationGeneration;
    try {
      await session.pause();
    } catch (error) {
      if (_isCurrent(generation, session)) {
        setState(
          () => _message = _safeMessage(error, 'Could not pause playback.'),
        );
      }
    }
  }

  Future<void> _stop(YlPlayerController player) async {
    final generation = ++_operationGeneration;
    final acceptedSession = _session;
    try {
      await player.stop();
      if (!_isCurrent(generation)) return;
      if (identical(_session, acceptedSession)) _session = null;
      setState(() => _message = 'Stopped');
    } catch (error) {
      if (_isCurrent(generation)) {
        setState(
          () => _message = _safeMessage(error, 'Could not stop playback.'),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('yl_player API example')),
    body: FutureBuilder<YlPlayerController>(
      future: _creation,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Center(child: Text('Player unavailable'));
        }
        final player = snapshot.data;
        if (player == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: YlPlayerView(controller: player),
            ),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Resolved HTTP(S) media URL',
              ),
            ),
            SwitchListTile(
              title: const Text('Live stream'),
              value: _live,
              onChanged: (value) => setState(() => _live = value),
            ),
            FilledButton(
              onPressed: () => unawaited(_load(player)),
              child: const Text('Load and play'),
            ),
            TextButton(
              onPressed: _session == null ? null : () => unawaited(_pause()),
              child: const Text('Pause'),
            ),
            TextButton(
              onPressed: () => unawaited(_stop(player)),
              child: const Text('Stop'),
            ),
            if (_message != null) Text(_message!),
          ],
        );
      },
    ),
  );
}
