import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yl_player/yl_player.dart';

import 'support/apple_strict_support.dart';
import 'support/dash_server.dart';

/// Same owned media and public expectations on Android, iOS and macOS.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const cases = <String, int>{
    'independent-pto': 4000,
    'clip-end': 3500,
    'gap': 9000,
    'overlap': 7000,
    'unknown-middle': 8000,
    'multiple-base': 4000,
    'fractional-microsecond': 334,
    'cross-codec': 3000,
    'resolution': 3000,
    'audio-added': 3000,
    'absolute-base': 4000,
    'absolute-list': 4000,
    'audio-gap-leading': 4000,
    'audio-gap-internal': 4000,
    'audio-gap-trailing': 4000,
    'video-gap-leading': 4000,
    'video-gap-internal': 4000,
    'video-gap-trailing': 4000,
  };
  testWidgets('managed DASH fixed AVC disappears and HEVC can be fixed', (
    tester,
  ) async {
    // The owned encoder is 24 fps; hvcC is Main, compatibility 6, level 63, constraints 90.
    // Fixed selection needs authoritative metadata for the device frame-rate envelope.
    final manifest =
        (await rootBundle.loadString(
              'assets/test_media/dash_timeline/cross-codec.mpd',
            ))
            .replaceAll(' width=', ' frameRate="24" width=')
            .replaceAll('codecs="hvc1"', 'codecs="hvc1.1.6.L63.90"');
    final server = await DashServer.start(
      timelineMarkers: true,
      manifestOverride: manifest,
    );
    addTearDown(server.close);
    final player = await appleController(tester);
    final session = await player.load(
      YlNetworkSource(server.automaticUri, networkPolicy: strictNetwork),
    );
    await session.ready.timeout(const Duration(seconds: 15));
    await stateWhere(player, (s) => s.videoTracks.isNotEmpty);
    await session.selectVideoTrack(player.state.videoTracks.first.id);
    await readyAndPlay(player, session);
    await stateWhere(
      player,
      (s) =>
          s.timeline.position.inMilliseconds >= 1800 &&
          s.videoGeometry?.encodedSize.width == 640,
    );
    expect(
      player.state.videoSelection.reason,
      YlVideoSelectionReason.trackUnavailable,
    );
    await session.pause();
    await session.selectVideoTrack(player.state.videoTracks.first.id);
    expect(player.state.videoSelection.isAutomatic, isFalse);
    await session.seekTo(const Duration(milliseconds: 2100));
    await session.play();
    await stateWhere(player, (s) => s.timeline.position.inMilliseconds >= 2300);
    expect(player.state.videoSelection.isAutomatic, isFalse);
    expect(player.state.videoGeometry?.encodedSize.width, 640);
    await session.pause();
    await session.seekTo(const Duration(milliseconds: 500));
    await session.play();
    await stateWhere(
      player,
      (s) =>
          s.timeline.position.inMilliseconds >= 700 &&
          s.timeline.position.inMilliseconds < 1500,
    );
    expect(
      player.state.videoSelection.reason,
      YlVideoSelectionReason.trackUnavailable,
    );
    expect(player.state.failure, isNull);
    await player.stop();
  });
  for (final entry in cases.entries) {
    testWidgets('managed DASH programme ${entry.key}', (tester) async {
      final file = entry.key.contains('-gap-') ? 'independent-pto' : entry.key;
      var manifest = await rootBundle.loadString(
        'assets/test_media/dash_timeline/$file.mpd',
      );
      if (entry.key.startsWith('audio-gap-')) {
        manifest = _audioGap(manifest, entry.key);
      }
      if (entry.key.startsWith('video-gap-')) {
        manifest = _videoGap(manifest, entry.key);
      }
      final server = await DashServer.start(
        timelineMarkers: true,
        manifestOverride: manifest,
      );
      addTearDown(server.close);
      final player = await appleController(tester);
      final observed = <YlPlayerState>[];
      final subscription = player.states.listen(observed.add);
      addTearDown(subscription.cancel);
      final session = await player.load(
        YlNetworkSource(server.automaticUri, networkPolicy: strictNetwork),
      );
      final watch = Stopwatch()..start();
      if (entry.key == 'gap') {
        final ready = await stateWhere(player, (s) => s.audioTracks.isNotEmpty);
        await session.selectAudioTrack(ready.audioTracks.first.id);
      }
      await readyAndPlay(player, session);
      final completed = await stateWhere(
        player,
        (s) => s.status == YlPlaybackStatus.completed,
      );
      expect(completed.failure, isNull);
      expect(completed.sessionId, session.id);
      expect(
        (completed.timeline.duration!.inMilliseconds - entry.value).abs(),
        lessThanOrEqualTo(2),
      );
      expect(
        (completed.timeline.position.inMilliseconds - entry.value).abs(),
        lessThanOrEqualTo(50),
        reason:
            'completed=${completed.timeline.position.inMilliseconds} '
            'duration=${completed.timeline.duration!.inMilliseconds} '
            'elapsed=${watch.elapsedMilliseconds} '
            'tail=${observed.reversed.take(5).map((s) => '${s.status}:${s.timeline.position.inMilliseconds}').toList()}',
      );
      expect(
        watch.elapsedMilliseconds,
        greaterThanOrEqualTo(entry.value - 180),
      );
      if (entry.key == 'gap') {
        expect(
          observed.any(
            (s) =>
                s.timeline.position.inMilliseconds >= 4200 &&
                s.timeline.position.inMilliseconds <= 4800 &&
                s.videoGeometry == null,
          ),
          isTrue,
          reason: 'The declared blank interval must hide the previous picture.',
        );
      }
      if (entry.key.startsWith('video-gap-')) {
        final (low, high) = switch (entry.key) {
          'video-gap-leading' => (80, 400),
          'video-gap-internal' => (1200, 1800),
          _ => (2400, 3600),
        };
        final inGap = observed.where(
          (s) =>
              s.timeline.position.inMilliseconds >= low &&
              s.timeline.position.inMilliseconds <= high,
        );
        expect(inGap, isNotEmpty);
        expect(
          inGap.every((s) => s.videoGeometry == null),
          isTrue,
          reason: 'No retained or early frame may be visible in a video gap.',
        );
        if (entry.key != 'video-gap-trailing') {
          expect(
            observed.any(
              (s) =>
                  s.timeline.position.inMilliseconds >= 2600 &&
                  s.videoGeometry != null,
            ),
            isTrue,
          );
        }
      }
      if (entry.key == 'cross-codec' || entry.key == 'resolution') {
        expect(
          observed.any((s) => s.videoGeometry?.encodedSize.width == 640),
          isTrue,
        );
      }
      if (entry.key == 'audio-added') {
        expect(completed.audioTracks, hasLength(2));
        final initial = observed.firstWhere(
          (s) => s.audioTracks.any((t) => t.isSelected),
        );
        expect(
          completed.audioTracks.singleWhere((t) => t.isSelected).id,
          initial.audioTracks.singleWhere((t) => t.isSelected).id,
        );
      }
      if (entry.value > 1000) {
        await session.pause();
        await session.seekTo(const Duration(milliseconds: 500));
        await session.play();
        await stateWhere(
          player,
          (s) =>
              s.status == YlPlaybackStatus.playing &&
              s.timeline.position.inMilliseconds >= 650 &&
              s.timeline.position.inMilliseconds < 1500,
        );
        expect(player.state.failure, isNull);
      }
      await player.stop();
      expect(player.state.status, YlPlaybackStatus.idle);
    });
  }
}

String _audioGap(String xml, String name) {
  if (name == 'audio-gap-leading') {
    return xml.replaceAll(
      'presentationTimeOffset="960000"',
      'presentationTimeOffset="936000"',
    );
  }
  final audio = xml.indexOf('<AdaptationSet contentType="audio"');
  final start = xml.indexOf('<SegmentTemplate', audio);
  final end =
      xml.indexOf('</SegmentTemplate>', start) + '</SegmentTemplate>'.length;
  final entries = name == 'audio-gap-trailing'
      ? [(1, 960000, 47104), (2, 1007104, 48128)]
      : [
          (1, 960000, 47104),
          (3, 1055232, 48128),
          (4, 1103360, 48128),
          (5, 1151488, 512),
        ];
  final timeline = entries.map((e) => '<S t="${e.$2}" d="${e.$3}"/>').join();
  final urls = entries
      .map(
        (e) =>
            '<SegmentURL media="chunk-1-${e.$1.toString().padLeft(5, '0')}.m4s"/>',
      )
      .join();
  return xml.replaceRange(
    start,
    end,
    '<SegmentList timescale="48000" presentationTimeOffset="960000"><Initialization sourceURL="init-1.m4s"/><SegmentTimeline>$timeline</SegmentTimeline>$urls</SegmentList>',
  );
}

String _videoGap(String xml, String name) {
  if (name == 'video-gap-leading') {
    return xml.replaceAll(
      'presentationTimeOffset="122880"',
      'presentationTimeOffset="116736"',
    );
  }
  final start = xml.indexOf('<SegmentTemplate');
  final end =
      xml.indexOf('</SegmentTemplate>', start) + '</SegmentTemplate>'.length;
  final numbers = name == 'video-gap-trailing' ? [1, 2] : [1, 3, 4];
  final timeline = numbers
      .map((n) => '<S t="${122880 + (n - 1) * 12288}" d="12288"/>')
      .join();
  final urls = numbers
      .map(
        (n) =>
            '<SegmentURL media="chunk-0-${n.toString().padLeft(5, '0')}.m4s"/>',
      )
      .join();
  return xml.replaceRange(
    start,
    end,
    '<SegmentList timescale="12288" presentationTimeOffset="122880"><Initialization sourceURL="init-0.m4s"/><SegmentTimeline>$timeline</SegmentTimeline>$urls</SegmentList>',
  );
}
