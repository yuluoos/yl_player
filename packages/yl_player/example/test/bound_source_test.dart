import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/bound_source.dart';

void main() {
  test(
    'owned HTTP source serves actual authorized ranges and rejects others',
    () async {
      final source = await BoundSource.serve(
        Uint8List.fromList([10, 20, 30, 40]),
        'case.mkv',
        'run',
        'hash',
      );
      addTearDown(source.close);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      var request = await client.getUrl(source.uri);
      var response = await request.close();
      expect(response.statusCode, 403);
      await response.drain<void>();
      request = await client.getUrl(source.uri);
      request.headers.set('x-yl-bound-run', 'run');
      request.headers.set('range', 'bytes=1-2');
      response = await request.close();
      expect(response.statusCode, 206);
      expect(response.headers.value('content-range'), 'bytes 1-2/4');
      expect(await response.expand((x) => x).toList(), [20, 30]);
      expect(source.receipt['bytesServed'], 2);
      expect(source.receipt['requests'], 1);
      expect(source.receipt['rejected'], 1);
    },
  );
}
