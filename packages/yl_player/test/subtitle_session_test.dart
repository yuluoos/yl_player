import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';

import 'support/fake_player_platform.dart';

const s1 = YlPlaybackSessionId('s1');
const s2 = YlPlaybackSessionId('s2');
final media = YlNetworkSource(Uri.parse('https://example.test/video'));
const subtitle = YlExternalSubtitle(
  id: 'en',
  source: YlFileSource('/sub.srt'),
  format: YlSubtitleFormat.srt,
);

Matcher failure(String code) => throwsA(
  isA<YlPlayerException>()
      .having((e) => e.failure.code, 'code', code)
      .having((e) => e.failure.scope, 'scope', YlFailureScope.command),
);

class SubtitleBackend extends FakePlatformPlayer
    implements YlSubtitlePlatformPlayer {
  SubtitleBackend({this.advertise = true});
  final bool advertise;
  @override
  YlPlayerCapabilities get capabilities => YlPlayerCapabilities(
    deviceProfile: 'subtitle-test',
    supportedOperations: advertise
        ? [
            YlPlayerOperation.externalSubtitles,
            YlPlayerOperation.subtitleTrackSelection,
            YlPlayerOperation.subtitleOffset,
          ]
        : [],
  );
  List<YlExternalSubtitle>? received;
  String? selected;
  Duration? offset;
  Completer<void>? ack;
  @override
  Future<void> replaceExternalSubtitles(
    YlPlaybackSessionId id,
    List<YlExternalSubtitle> subtitles,
  ) async {
    received = subtitles;
    await command('subtitles', id);
    await ack?.future;
  }

  @override
  Future<void> selectSubtitleTrack(
    YlPlaybackSessionId id,
    String? trackId,
  ) async {
    selected = trackId;
    await command('selection', id);
    await ack?.future;
  }

  @override
  Future<void> setSubtitleOffset(YlPlaybackSessionId id, Duration value) async {
    offset = value;
    await command('offset', id);
    await ack?.future;
  }
}

class AdvertisingLegacyBackend extends FakePlatformPlayer {
  @override
  YlPlayerCapabilities get capabilities => YlPlayerCapabilities(
    deviceProfile: 'legacy',
    supportedOperations: [
      YlPlayerOperation.externalSubtitles,
      YlPlayerOperation.subtitleTrackSelection,
      YlPlayerOperation.subtitleOffset,
    ],
  );
}

Future<(YlPlayerController, YlPlaybackSession)> load(
  FakePlatformPlayer backend,
) async {
  final player = await YlPlayerController.create(
    platform: FakePlayerPlatform(backend),
  );
  final pending = player.load(media);
  backend.commit(s1);
  return (player, await pending);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final backendFactory in <FakePlatformPlayer Function()>[
    FakePlatformPlayer.new,
    AdvertisingLegacyBackend.new,
    () => SubtitleBackend(advertise: false),
  ]) {
    test(
      'legacy/interface/capability gates ${backendFactory.hashCode}',
      () async {
        final backend = backendFactory();
        final (player, session) = await load(backend);
        addTearDown(player.dispose);
        await expectLater(
          session.replaceExternalSubtitles([subtitle]),
          failure(YlFailureCodes.policyUnsupported),
        );
        await expectLater(
          session.selectSubtitleTrack(null),
          failure(YlFailureCodes.policyUnsupported),
        );
        await expectLater(
          session.setSubtitleOffset(Duration.zero),
          failure(YlFailureCodes.policyUnsupported),
        );
        expect(backend.calls, isEmpty);
      },
    );
  }

  test(
    'supported commands validate, snapshot input, await ACK and do not invent state',
    () async {
      final backend = SubtitleBackend()..ack = Completer<void>();
      final (player, session) = await load(backend);
      addTearDown(player.dispose);
      final before = player.state;
      final list = [subtitle];
      var done = false;
      final pending = session
          .replaceExternalSubtitles(list)
          .then((_) => done = true);
      list.clear();
      await Future<void>.delayed(Duration.zero);
      expect(done, isFalse);
      expect(backend.received, [subtitle]);
      expect(() => backend.received!.clear(), throwsUnsupportedError);
      backend.ack!.complete();
      await pending;
      backend.ack = null;
      await session.selectSubtitleTrack('en');
      expect(backend.selected, 'en');
      await session.selectSubtitleTrack(null);
      expect(backend.selected, isNull);
      await session.setSubtitleOffset(const Duration(milliseconds: -500));
      expect(backend.offset, const Duration(milliseconds: -500));
      expect(backend.lastCommand, ('offset', s1));
      expect(player.state, before);
      final count = backend.calls.length;
      await expectLater(session.selectSubtitleTrack(''), throwsArgumentError);
      await expectLater(
        session.replaceExternalSubtitles([subtitle, subtitle]),
        throwsArgumentError,
      );
      await expectLater(
        session.setSubtitleOffset(const Duration(microseconds: 1)),
        throwsArgumentError,
      );
      expect(backend.calls.length, count);
    },
  );

  test(
    'authoritative subtitle state is preserved and current command failures propagate',
    () async {
      final backend = SubtitleBackend();
      final (player, session) = await load(backend);
      addTearDown(player.dispose);
      final subtitles = YlSubtitleState(
        tracks: [
          const YlSubtitleTrack(
            id: 'en',
            format: YlSubtitleFormat.srt,
            isExternal: true,
          ),
        ],
        selectedTrackId: 'en',
        offset: const Duration(seconds: 1),
      );
      backend.emitState(
        backend.state.copyWith(
          revision: backend.state.revision + 1,
          subtitles: subtitles,
        ),
      );
      expect(player.state.subtitles, subtitles);
      const rejection = YlPlayerException(
        YlFailure(
          category: YlFailureCategory.unsupported,
          code: YlFailureCodes.policyUnsupported,
          message: 'Unsupported subtitle format.',
          retryable: false,
          scope: YlFailureScope.command,
          diagnosticId: 'subtitle-test',
        ),
      );
      backend.commandError = rejection;
      await expectLater(
        session.selectSubtitleTrack(null),
        throwsA(same(rejection)),
      );
      expect(player.state.subtitles, subtitles);
    },
  );

  for (final command in ['replace', 'select', 'offset']) {
    for (final lifecycle in ['replace', 'stop', 'dispose']) {
      for (final rejected in [false, true]) {
        test(
          '$command late ${rejected ? 'failure' : 'ACK'} after $lifecycle is stale',
          () async {
            final backend = SubtitleBackend()..ack = Completer<void>();
            final (player, session) = await load(backend);
            addTearDown(player.dispose);
            final pending = switch (command) {
              'replace' => session.replaceExternalSubtitles([subtitle]),
              'select' => session.selectSubtitleTrack('en'),
              _ => session.setSubtitleOffset(Duration.zero),
            };
            final assertion = expectLater(
              pending,
              failure(
                lifecycle == 'dispose'
                    ? YlFailureCodes.playerDisposed
                    : YlFailureCodes.sessionStale,
              ),
            );
            await Future<void>.delayed(Duration.zero);
            if (lifecycle == 'replace') {
              final next = player.load(media);
              backend.commit(s2);
              await next;
            } else if (lifecycle == 'stop') {
              await player.stop();
            } else {
              await player.dispose();
            }
            if (rejected) {
              backend.ack!.completeError(StateError('old private error'));
            } else {
              backend.ack!.complete();
            }
            await assertion;
            expect(player.state.subtitles, YlSubtitleState());
          },
        );
      }
    }
  }

  test(
    'stale session rejects before argument validation or platform dispatch',
    () async {
      final backend = SubtitleBackend();
      final (player, session) = await load(backend);
      addTearDown(player.dispose);
      await player.stop();
      await expectLater(
        session.selectSubtitleTrack(''),
        failure(YlFailureCodes.sessionStale),
      );
      await expectLater(
        session.replaceExternalSubtitles([subtitle]),
        failure(YlFailureCodes.sessionStale),
      );
      await expectLater(
        session.setSubtitleOffset(Duration.zero),
        failure(YlFailureCodes.sessionStale),
      );
    },
  );
}
