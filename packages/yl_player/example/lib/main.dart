import 'dart:async';

import 'package:flutter/material.dart';
import 'package:yl_player/yl_player.dart';

void main() => runApp(const PlayerExampleApp());

class PlayerExampleApp extends StatelessWidget {
  const PlayerExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const PlayerExamplePage(),
  );
}

class PlayerExamplePage extends StatefulWidget {
  const PlayerExamplePage({super.key});

  @override
  State<PlayerExamplePage> createState() => _PlayerExamplePageState();
}

class _PlayerExamplePageState extends State<PlayerExamplePage> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _refererController = TextEditingController();
  late final YlPlayerController _controller;
  late final StreamSubscription<YlPlayerState> _stateSubscription;
  YlPlayerState _state = YlPlayerState();
  YlFormatHint _formatHint = YlFormatHint.automatic;
  bool _isLive = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _controller = YlPlayerController();
    _stateSubscription = _controller.states.listen((state) {
      if (mounted) {
        setState(() => _state = state);
      }
    });
  }

  @override
  void dispose() {
    unawaited(_stateSubscription.cancel());
    unawaited(_controller.dispose());
    _urlController.dispose();
    _refererController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('yl_player API example')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Milestone 1 exposes the public API only; native playback backends '
          'are not included yet.',
        ),
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(
            color: Colors.black,
            child: YlPlayerView(
              controller: _controller,
              placeholder: const Center(
                child: Text(
                  'Waiting for a native texture',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text('Status: ${_state.status.name}'),
        if (_message != null) Text(_message!),
        const SizedBox(height: 12),
        TextField(
          controller: _urlController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Resolved HTTP(S) media URL',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _refererController,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Referer header (optional)',
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<YlFormatHint>(
                initialValue: _formatHint,
                decoration: const InputDecoration(labelText: 'Format'),
                items: const [
                  DropdownMenuItem(
                    value: YlFormatHint.automatic,
                    child: Text('Automatic'),
                  ),
                  DropdownMenuItem(value: YlFormatHint.hls, child: Text('HLS')),
                  DropdownMenuItem(
                    value: YlFormatHint.httpFlv,
                    child: Text('HTTP-FLV'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _formatHint = value);
                  }
                },
              ),
            ),
            const SizedBox(width: 12),
            const Text('Live'),
            Switch(
              value: _isLive,
              onChanged: (value) => setState(() => _isLive = value),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(onPressed: _open, child: const Text('Open source')),
            OutlinedButton(
              onPressed: () => _runCommand(_controller.play),
              child: const Text('Play'),
            ),
            OutlinedButton(
              onPressed: () => _runCommand(_controller.pause),
              child: const Text('Pause'),
            ),
          ],
        ),
      ],
    ),
  );

  Future<void> _open() async {
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
      setState(() => _message = 'Enter a valid HTTP(S) URL.');
      return;
    }

    final referer = _refererController.text.trim();
    final headers = referer.isEmpty
        ? const <String, String>{}
        : {'Referer': referer};
    await _runCommand(
      () => _controller.open(
        YlMediaSource.network(
          uri,
          isLive: _isLive,
          formatHint: _formatHint,
          headers: headers,
        ),
      ),
    );
  }

  Future<void> _runCommand(Future<void> Function() command) async {
    try {
      await command();
      if (mounted) {
        setState(() => _message = null);
      }
    } on YlPlayerError catch (error) {
      if (mounted) {
        setState(() => _message = '${error.code}: ${error.message}');
      }
    } on Object catch (error) {
      if (mounted) {
        setState(() => _message = error.toString());
      }
    }
  }
}
