import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'package:yl_player_apple/src/apple_player.dart';
import 'package:yl_player_apple/src/apple_drm.dart';
import 'package:yl_player_apple/src/pigeon/yl_player_apple.g.dart';
import '../../yl_player_apple/test/support/apple_fakes.dart' as fake;

class _Platform extends YlPlayerPlatform {
  _Platform(this.player);
  final ApplePlayer player;
  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) async =>
      player;
}

class _Http extends HttpOverrides {}

class _Host extends AppleDrmHostApi {
  final attached = Completer<AppleProtectedViewAck>();
  @override
  Future<AppleProtectedViewAck> attachProtectedView(
    AppleProtectedViewCommand command,
  ) => attached.future;
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'generated challenge reaches real POST and first frame waits for matching view ACK',
    () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        var posts = 0;
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          posts++;
          expect(request.method, 'POST');
          expect(request.headers.value('authorization'), 'Bearer owned');
          expect(await request.fold<List<int>>([], (a, b) => a..addAll(b)), [
            7,
          ]);
          if (posts == 2) {
            request.response.statusCode = 307;
            request.response.headers.set(
              'location',
              'https://another-origin.test/license',
            );
          } else {
            request.response.add([8]);
          }
          await request.response.close();
        });
        final transport = fake.FakeTransport();
        final create = fake.wireCreate(suffix: 'drm-combined')
          ..drmSupport = AppleDrmSupportMessage(
            contractVersion: 1,
            playerId: 1,
            platform: ApplePlatform.ios,
            schemeAvailable: true,
          );
        final host = _Host();
        late AppleDrmChannel drm;
        final player = await ApplePlayer.create(
          const YlPlayerOptions(),
          factory: fake.FakeFactory(create),
          transportForSuffix: (_) => transport,
          setupCallbacks: (_, cb) => transport.callbacks = cb,
          drmFactory: (suffix, support) =>
              drm = AppleDrmChannel(suffix, support, host: host),
        );
        final controller = await YlPlayerController.create(
          platform: _Platform(player),
        );
        addTearDown(controller.dispose);
        final source = YlNetworkSource(
          Uri.parse('https://media.test/a.m3u8'),
          format: YlMediaFormat.hls,
          drm: YlFairPlayDrm(
            certificate: YlDrmBytes([1]),
            contentId: YlDrmBytes([2]),
            license: YlDrmLicenseEndpoint(
              Uri.parse('http://127.0.0.1:${server.port}/license'),
              allowInsecureLoopback: true,
              request: YlHttpRequest(
                credentials: {'Authorization': 'Bearer owned'},
              ),
            ),
          ),
        );
        final loading = controller.load(source);
        await fake.flush();
        final surface = AppleProtectedSurfaceMessage(
          playerId: 1,
          surfaceId: 2,
          sessionId: 's1',
          generation: 3,
        );
        final request = AppleDrmLicenseRequest(
          id: AppleDrmExchangeId(
            surface: surface,
            loadRequestId: 'load-1',
            epoch: 1,
            requestId: 1,
            exchangeId: 'exchange-1',
          ),
          challenge: Uint8List.fromList([7]),
        );
        final replyBytes = Completer<ByteData?>();
        await binding.defaultBinaryMessenger.handlePlatformMessage(
          'dev.flutter.pigeon.yl_player_apple.AppleDrmFlutterApi.exchangeLicense.drm-combined',
          AppleDrmFlutterApi.pigeonChannelCodec.encodeMessage([request]),
          replyBytes.complete,
        );
        final wire =
            AppleDrmFlutterApi.pigeonChannelCodec.decodeMessage(
                  await replyBytes.future,
                )
                as List;
        expect((wire.single as AppleDrmLicenseReply).response, [8]);
        expect(posts, 1);
        final redirectedRequest = AppleDrmLicenseRequest(
          id: AppleDrmExchangeId(
            surface: surface,
            loadRequestId: 'load-1',
            epoch: 1,
            requestId: 2,
            exchangeId: 'exchange-2',
          ),
          challenge: Uint8List.fromList([7]),
        );
        final redirectBytes = Completer<ByteData?>();
        await binding.defaultBinaryMessenger.handlePlatformMessage(
          'dev.flutter.pigeon.yl_player_apple.AppleDrmFlutterApi.exchangeLicense.drm-combined',
          AppleDrmFlutterApi.pigeonChannelCodec.encodeMessage([
            redirectedRequest,
          ]),
          redirectBytes.complete,
        );
        final redirectWire =
            AppleDrmFlutterApi.pigeonChannelCodec.decodeMessage(
                  await redirectBytes.future,
                )
                as List;
        expect(
          (redirectWire.single as AppleDrmLicenseReply).failureCode,
          YlFailureCodes.drmLicenseRedirectRejected,
        );
        expect(posts, 2);
        expect(transport.requests.single.source.drm?.certificate, [1]);
        expect(transport.requests.single.source.request?.credentials, isEmpty);
        transport.callbacks!.onState(
          fake.wireState(
            session: 's1',
            revision: 1,
            sequence: 1,
            status: ApplePlaybackStatus.ready,
          ),
        );
        transport.loads.single.complete(
          AppleLoadReply(
            loadRequestId: 'load-1',
            sessionId: 's1',
            protectedSurface: surface,
          ),
        );
        final session = await loading;
        final publicSurface = controller.protectedVideoSurface!;
        final attaching = controller.attachProtectedView(publicSurface, 10);
        drm.onProtectedFrame(
          AppleProtectedViewAck(
            surface: surface,
            viewId: 10,
            revision: 1,
            attached: true,
          ),
        );
        transport.callbacks!.onFirstFrame(
          fake.wireFrame(session: 's1', revision: 2, sequence: 2),
        );
        await fake.flush();
        expect(controller.isCurrentFramePresented, isFalse);
        host.attached.complete(
          AppleProtectedViewAck(
            surface: surface,
            viewId: 10,
            revision: 1,
            attached: true,
          ),
        );
        await attaching;
        await session.firstFrame;
        expect(controller.isCurrentFramePresented, isTrue);
        await controller.stop();
        expect(controller.protectedVideoSurface, isNull);
        final stale = await drm.exchangeLicense(request);
        expect(stale.failureCode, YlFailureCodes.loadCancelled);
        expect(posts, 2);
      }, _Http());
    },
  );
}
