import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/live_flv_server.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'first live connection drops and the next connection still streams',
    () async {
      final server = await LiveFlvServer.start(
        asset: 'assets/test_media/h264_aac.flv',
        disconnectFirstConnection: true,
        chunkDelay: Duration.zero,
      );
      addTearDown(server.close);
      final firstBytes = await _readUntilClosed(server.streamUri);
      final firstResponse = _splitResponse(firstBytes);
      final declaredLength = int.parse(
        RegExp(
          r'^content-length: (\d+)$',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(firstResponse.headers)!.group(1)!,
      );
      expect(firstResponse.body.take(3), <int>[0x46, 0x4c, 0x56]);
      expect(firstResponse.body.length, lessThan(declaredLength));

      final secondResponse = await _readBodyBytesAtLeast(
        server.streamUri,
        minimumBodyBytes: 100000,
      );
      expect(secondResponse.headers, contains('200 OK'));
      expect(
        _containsBytes(secondResponse.body, <int>[0x46, 0x4c, 0x56]),
        isTrue,
      );
      expect(server.connectionCount, 2);
    },
  );
}

bool _containsBytes(List<int> bytes, List<int> expected) {
  for (var offset = 0; offset <= bytes.length - expected.length; offset += 1) {
    var matches = true;
    for (var index = 0; index < expected.length; index += 1) {
      if (bytes[offset + index] != expected[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Future<List<int>> _readUntilClosed(Uri uri) async {
  final socket = await Socket.connect(uri.host, uri.port);
  socket.write('GET ${uri.path} HTTP/1.1\r\nHost: ${uri.host}\r\n\r\n');
  await socket.flush();
  try {
    return await socket
        .fold<List<int>>(<int>[], (bytes, chunk) => bytes..addAll(chunk))
        .timeout(const Duration(seconds: 2));
  } finally {
    socket.destroy();
  }
}

Future<_RawResponse> _readBodyBytesAtLeast(
  Uri uri, {
  required int minimumBodyBytes,
}) async {
  final socket = await Socket.connect(uri.host, uri.port);
  socket.write('GET ${uri.path} HTTP/1.1\r\nHost: ${uri.host}\r\n\r\n');
  await socket.flush();
  final iterator = StreamIterator<List<int>>(socket);
  final bytes = <int>[];
  try {
    while (await iterator.moveNext().timeout(const Duration(seconds: 2))) {
      bytes.addAll(iterator.current);
      final response = _trySplitResponse(bytes);
      if (response != null &&
          response.body.length >= minimumBodyBytes &&
          _containsBytes(response.body, <int>[0x46, 0x4c, 0x56])) {
        return response;
      }
    }
    throw StateError('The live response closed before its FLV body arrived.');
  } finally {
    await iterator.cancel();
    socket.destroy();
  }
}

_RawResponse _splitResponse(List<int> bytes) =>
    _trySplitResponse(bytes) ??
    (throw StateError('Missing HTTP response header.'));

_RawResponse? _trySplitResponse(List<int> bytes) {
  const delimiter = <int>[13, 10, 13, 10];
  for (var index = 0; index <= bytes.length - delimiter.length; index += 1) {
    if (bytes[index] == delimiter[0] &&
        bytes[index + 1] == delimiter[1] &&
        bytes[index + 2] == delimiter[2] &&
        bytes[index + 3] == delimiter[3]) {
      return _RawResponse(
        headers: ascii.decode(bytes.sublist(0, index)),
        body: bytes.sublist(index + delimiter.length),
      );
    }
  }
  return null;
}

final class _RawResponse {
  const _RawResponse({required this.headers, required this.body});

  final String headers;
  final List<int> body;
}
