import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/range_media_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Range fixture serves a standard GET and preserves ranged and invalid responses',
    () async {
      final server = await RangeMediaServer.start(
        asset: 'assets/test_media/h264_aac.mkv',
      );
      addTearDown(server.close);
      final client = HttpOverrides.runWithHttpOverrides(
        () => HttpClient(),
        _LoopbackHttpOverrides(),
      );
      addTearDown(() => client.close(force: true));
      final full = await (await client.getUrl(server.mediaUri)).close();
      expect(full.statusCode, 200);
      final bytes = await full.fold<List<int>>(
        [],
        (result, chunk) => result..addAll(chunk),
      );
      expect(bytes, isNotEmpty);
      final request = await client.getUrl(server.mediaUri);
      request.headers.set('Range', 'bytes=2-9');
      final ranged = await request.close();
      expect(ranged.statusCode, 206);
      expect(
        await ranged.fold<List<int>>(
          [],
          (result, chunk) => result..addAll(chunk),
        ),
        bytes.sublist(2, 10),
      );
      final invalid = await client.getUrl(server.mediaUri);
      invalid.headers.set('Range', 'invalid');
      final rejected = await invalid.close();
      expect(rejected.statusCode, 416);
      await rejected.drain<void>();
    },
  );
}

class _LoopbackHttpOverrides extends HttpOverrides {}
