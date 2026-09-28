import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player/yl_player.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'package:yl_player_android/src/android_player.dart';
import 'package:yl_player_android/src/android_drm.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';
import '../../yl_player_android/test/support/android_fakes.dart' as fake;

class _Platform extends YlPlayerPlatform {
  _Platform(this.player);
  final AndroidPlayer player;
  @override
  Future<YlPlatformPlayer> createPlayer(YlPlayerOptions options) async =>
      player;
}

class _Http extends HttpOverrides {}

class _Host extends AndroidDrmHostApi {
  final attached = Completer<AndroidProtectedViewAck>();
  @override
  Future<AndroidProtectedViewAck> attachProtectedView(
    AndroidProtectedViewCommand command,
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
          ..drmSupport = AndroidDrmSupportMessage(
            contractVersion: 1,
            playerId: 1,
            androidApi: 35,
            schemeAvailable: true,
          );
        final host = _Host();
        late AndroidDrmChannel drm;
        final player = await AndroidPlayer.create(
          const YlPlayerOptions(),
          factory: fake.FakeFactory(create),
          transportForSuffix: (_) => transport,
          setupCallbacks: (_, cb) => transport.callbacks = cb,
          drmFactory: (suffix, support) =>
              drm = AndroidDrmChannel(suffix, support, host: host),
        );
        final controller = await YlPlayerController.create(
          platform: _Platform(player),
        );
        addTearDown(controller.dispose);
        final source = YlNetworkSource(
          Uri.parse('https://media.test/a.mpd'),
          format: YlMediaFormat.dash,
          drm: YlWidevineDrm(
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
        final surface = AndroidProtectedSurfaceMessage(
          playerId: 1,
          surfaceId: 2,
          sessionId: 's1',
          generation: 3,
        );
        final request = AndroidDrmLicenseRequest(
          id: AndroidDrmExchangeId(
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
          'dev.flutter.pigeon.yl_player_android.AndroidDrmFlutterApi.exchangeLicense.drm-combined',
          AndroidDrmFlutterApi.pigeonChannelCodec.encodeMessage([request]),
          replyBytes.complete,
        );
        final wire =
            AndroidDrmFlutterApi.pigeonChannelCodec.decodeMessage(
                  await replyBytes.future,
                )
                as List;
        expect((wire.single as AndroidDrmLicenseReply).response, [8]);
        expect(posts, 1);
        final redirectedRequest = AndroidDrmLicenseRequest(
          id: AndroidDrmExchangeId(
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
          'dev.flutter.pigeon.yl_player_android.AndroidDrmFlutterApi.exchangeLicense.drm-combined',
          AndroidDrmFlutterApi.pigeonChannelCodec.encodeMessage([
            redirectedRequest,
          ]),
          redirectBytes.complete,
        );
        final redirectWire =
            AndroidDrmFlutterApi.pigeonChannelCodec.decodeMessage(
                  await redirectBytes.future,
                )
                as List;
        expect(
          (redirectWire.single as AndroidDrmLicenseReply).failureCode,
          YlFailureCodes.drmLicenseRedirectRejected,
        );
        expect(posts, 2);
        expect(transport.requests.single.source.drm?.cbcs, isFalse);
        expect(transport.requests.single.source.request?.credentials, isEmpty);
        transport.callbacks!.onState(
          fake.wireState(
            session: 's1',
            revision: 1,
            sequence: 1,
            status: AndroidPlaybackStatus.ready,
          ),
        );
        transport.loads.single.complete(
          AndroidLoadReply(
            loadRequestId: 'load-1',
            sessionId: 's1',
            protectedSurface: surface,
          ),
        );
        final session = await loading;
        final publicSurface = controller.protectedVideoSurface!;
        final attaching = controller.attachProtectedView(publicSurface, 10);
        drm.onProtectedFrame(
          AndroidProtectedViewAck(
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
          AndroidProtectedViewAck(
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
