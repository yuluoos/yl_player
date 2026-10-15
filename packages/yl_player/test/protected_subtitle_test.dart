import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'package:yl_player/src/subtitles/text_subtitle_overlay.dart';
import 'support/fake_player_platform.dart';

class ProtectedBackend extends FakePlatformPlayer
    implements
        YlPlatformProtectedVideoSurfaceProvider,
        YlPlatformDrmSourceSupport {
  ProtectedBackend(this.platform, {this.overlay = true});
  final TargetPlatform platform;
  bool overlay;
  String owner = 'protected';
  bool available = true;
  @override
  int get drmContractVersion => 1;
  @override
  YlProtectedVideoSurface? get protectedVideoSurface => available
      ? YlProtectedVideoSurface(
          playerId: 1,
          surfaceId: 2,
          sessionId: owner,
          generation: 3,
          platform: platform,
          viewType: 'owned/protected',
          supportsSubtitleOverlay: overlay,
        )
      : null;
  @override
  Future<void> attachProtectedView(
    YlProtectedVideoSurface surface,
    int id,
  ) async {}
  @override
  Future<void> detachProtectedView(
    YlProtectedVideoSurface surface,
    int id,
  ) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sid = YlPlaybackSessionId('protected');
  const geometry = YlVideoGeometry(
    encodedSize: YlPixelSize(1920, 1080),
    displaySize: YlPixelSize(1920, 1080),
  );
  late Directory dir;
  late YlExternalSubtitle subtitle;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('protected-sub-');
    final file = await File(
      '${dir.path}/owned.srt',
    ).writeAsString('1\n00:00:01,000 --> 00:00:03,000\nindependent overlay\n');
    subtitle = YlExternalSubtitle(
      id: 'external',
      source: YlFileSource(file.path),
      format: YlSubtitleFormat.srt,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (_) async => null,
        );
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform_views, null);
    await dir.delete(recursive: true);
  });
  Future<(YlPlayerController, YlPlaybackSession)> load(
    ProtectedBackend backend,
  ) async {
    final player = await YlPlayerController.create(
      platform: FakePlayerPlatform(backend),
      enableTextSubtitles: true,
    );
    final pending = player.load(
      YlNetworkSource(
        Uri.parse('https://unreachable.invalid/protected.mpd'),
        format: YlMediaFormat.dash,
        drm: YlWidevineDrm(
          license: YlDrmLicenseEndpoint(
            Uri.parse('https://unreachable.invalid/license'),
          ),
        ),
      ),
    );
    backend.commit(sid);
    return (player, await pending);
  }

  void position(ProtectedBackend backend, {bool aperture = true}) =>
      backend.emitState(
        backend.state.copyWith(
          revision: backend.state.revision + 1,
          status: YlPlaybackStatus.playing,
          timeline: const YlTimeline(position: Duration(milliseconds: 1500)),
          videoGeometry: aperture ? geometry : null,
        ),
      );
  Matcher denied() => throwsA(
    isA<YlPlayerException>().having(
      (e) => e.failure.code,
      'code',
      YlFailureCodes.policyUnsupported,
    ),
  );

  test(
    'protected external resource admission fails closed for missing or stale capability',
    () async {
      final backend = ProtectedBackend(TargetPlatform.android, overlay: false);
      final (player, session) = await load(backend);
      addTearDown(player.dispose);
      await expectLater(session.replaceExternalSubtitles([subtitle]), denied());
      backend.overlay = true;
      backend.owner = 'old';
      await expectLater(session.replaceExternalSubtitles([subtitle]), denied());
      backend.owner = sid.value;
      backend.available = false;
      await expectLater(session.replaceExternalSubtitles([subtitle]), denied());
      backend.available = true;
      await session.replaceExternalSubtitles([subtitle]);
      await session.selectSubtitleTrack('external');
      // No DNS request or protected manifest demux; selection remains usable.
      await expectLater(session.discoverEmbeddedSubtitles(), denied());
      expect(player.state.subtitles.selectedTrackId, 'external');
    },
  );

  for (final platform in [
    TargetPlatform.android,
    TargetPlatform.iOS,
    TargetPlatform.macOS,
  ]) {
    testWidgets(
      'protected $platform uses separate overlay with identity/frame/geometry gates',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final backend = ProtectedBackend(platform);
        final (player, session) = await load(backend);
        addTearDown(player.dispose);
        await tester.runAsync(
          () => session.replaceExternalSubtitles([subtitle]),
        );
        await session.selectSubtitleTrack('external');
        position(backend);
        await tester.pumpWidget(
          Directionality(
            textDirection: TextDirection.ltr,
            child: SizedBox(
              width: 320,
              height: 240,
              child: YlPlayerView(controller: player),
            ),
          ),
        );
        expect(find.byType(TextSubtitleOverlay), findsNothing);
        backend.emitFirstFrame(sid);
        await tester.pump();
        expect(
          find.text('independent overlay', findRichText: true),
          findsOneWidget,
        );
        expect(find.byType(Texture), findsNothing);
        expect(find.byType(Opacity), findsNothing);
        expect(find.byType(RepaintBoundary), findsNothing);
        position(backend, aperture: false);
        await tester.pump();
        expect(find.byType(TextSubtitleOverlay), findsNothing);
        position(backend);
        await tester.pump();
        expect(find.byType(TextSubtitleOverlay), findsOneWidget);
        backend.owner = 'old';
        position(backend);
        await tester.pump();
        expect(find.byType(TextSubtitleOverlay), findsNothing);
        backend.owner = sid.value;
        position(backend);
        await tester.pump();
        await session.selectSubtitleTrack(null);
        await tester.pump();
        expect(find.byType(TextSubtitleOverlay), findsNothing);
        await tester.pumpWidget(const SizedBox());
        debugDefaultTargetPlatformOverride = null;
      },
    );
  }
}
