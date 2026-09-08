import 'dart:async';
import 'package:flutter/material.dart';
import 'package:yl_player/yl_player.dart';

void main() => runApp(const PlayerExampleApp());

class PlayerExampleApp extends StatelessWidget {
  const PlayerExampleApp({super.key});
  @override
  Widget build(BuildContext context) =>
      MaterialApp(home: const PlayerExamplePage());
}

class PlayerExamplePage extends StatefulWidget {
  const PlayerExamplePage({super.key});
  @override
  State<PlayerExamplePage> createState() => _PlayerExamplePageState();
}

class _PlayerExamplePageState extends State<PlayerExamplePage> {
  final _url = TextEditingController();
  late final Future<YlPlayerController> _creation;
  YlPlaybackSession? _session;
  bool _live = false;
  String? _message;
  @override
  void initState() {
    super.initState();
    _creation = YlPlayerController.create();
  }

  @override
  void dispose() {
    unawaited(
      _creation.then(
        (player) => player.dispose(),
        onError: (Object _, StackTrace _) {},
      ),
    );
    _url.dispose();
    super.dispose();
  }

  Future<void> _load(YlPlayerController player) async {
    try {
      final session = await player.load(
        YlNetworkSource(
          Uri.parse(_url.text),
          intent: _live ? YlStreamIntent.live : YlStreamIntent.onDemand,
        ),
      );
      _session = session;
      await session.play();
      await session.ready;
      if (mounted) setState(() => _message = 'Ready');
      await session.firstFrame;
      if (mounted) setState(() => _message = 'First frame displayed');
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = error is YlPlayerException
              ? error.failure.message
              : 'Could not load media.',
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
              onPressed: () => _load(player),
              child: const Text('Load and play'),
            ),
            TextButton(
              onPressed: () => _session?.pause(),
              child: const Text('Pause'),
            ),
            TextButton(
              onPressed: () => player.stop(),
              child: const Text('Stop'),
            ),
            if (_message != null) Text(_message!),
          ],
        );
      },
    ),
  );
}
