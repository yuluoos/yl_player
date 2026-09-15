import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_android/src/pigeon/yl_player_android.g.dart';

const _maxInt64 = 0x7fffffffffffffff;

void main() {
  test(
    'Android periodic callback stays typed, lossless, and below 768 bytes',
    () {
      final maximal = AndroidStateDeltaMessage(
        sessionId: 'a$_maxInt64-s$_maxInt64',
        previousRevision: _maxInt64 - 1,
        revision: _maxInt64,
        sequence: _maxInt64,
        positionMs: _maxInt64,
        bufferedPositionMs: _maxInt64,
        hasIsAtLiveEdge: true,
        isAtLiveEdge: true,
        hasLiveOffsetMs: true,
        liveOffsetMs: _maxInt64,
        metrics: AndroidMetricsDeltaMessage(
          hasMediaClockPositionMs: true,
          mediaClockPositionMs: _maxInt64,
          hasLoadToReadyMs: true,
          loadToReadyMs: _maxInt64,
          hasLoadToFirstFrameMs: true,
          loadToFirstFrameMs: _maxInt64,
          hasRebufferCount: true,
          rebufferCount: _maxInt64,
          hasRebufferDurationMs: true,
          rebufferDurationMs: _maxInt64,
          hasDroppedVideoFrames: true,
          droppedVideoFrames: _maxInt64,
          hasAudioUnderruns: true,
          audioUnderruns: _maxInt64,
          hasEstimatedBitrate: true,
          estimatedBitrate: _maxInt64,
          hasManagedBufferedDurationMs: true,
          managedBufferedDurationMs: _maxInt64,
          hasManagedBufferedBytes: true,
          managedBufferedBytes: _maxInt64,
          hasLiveOffsetMs: true,
          liveOffsetMs: _maxInt64,
          hasReconnectCount: true,
          reconnectCount: _maxInt64,
        ),
      );
      const MessageCodec<Object?> codec =
          AndroidPlayerFlutterApi.pigeonChannelCodec;
      final bytes = codec.encodeMessage(<Object?>[maximal])!;
      final envelope = codec.decodeMessage(bytes)! as List<Object?>;
      final decoded = envelope.single! as AndroidStateDeltaMessage;

      expect(bytes.lengthInBytes, lessThan(768));
      expect(decoded.sessionId, 'a$_maxInt64-s$_maxInt64');
      expect(decoded.previousRevision, _maxInt64 - 1);
      expect(decoded.revision, _maxInt64);
      expect(decoded.sequence, _maxInt64);
      expect(decoded.positionMs, _maxInt64);
      expect(decoded.bufferedPositionMs, _maxInt64);
      expect(decoded.isAtLiveEdge, isTrue);
      expect(decoded.liveOffsetMs, _maxInt64);
      expect(decoded.metrics!.managedBufferedBytes, _maxInt64);
      expect(decoded.metrics!.reconnectCount, _maxInt64);
      expect(decoded.metrics!.mediaClockPositionMs, _maxInt64);
      // Printed output is retained by the release evidence log.
      // ignore: avoid_print
      print('ANDROID_MAX_CALLBACK_BYTES=${bytes.lengthInBytes}');
    },
  );

  test('Android callback codec preserves explicit nullable clears', () {
    final clear = AndroidStateDeltaMessage(
      sessionId: 'a$_maxInt64-s$_maxInt64',
      previousRevision: _maxInt64 - 1,
      revision: _maxInt64,
      sequence: _maxInt64,
      hasIsAtLiveEdge: true,
      hasLiveOffsetMs: true,
      metrics: AndroidMetricsDeltaMessage(
        hasMediaClockPositionMs: true,
        hasLoadToReadyMs: true,
        hasLoadToFirstFrameMs: true,
        hasRebufferCount: true,
        hasRebufferDurationMs: true,
        hasDroppedVideoFrames: true,
        hasAudioUnderruns: true,
        hasEstimatedBitrate: true,
        hasManagedBufferedDurationMs: true,
        hasManagedBufferedBytes: true,
        hasLiveOffsetMs: true,
        hasReconnectCount: true,
      ),
    );
    const codec = AndroidPlayerFlutterApi.pigeonChannelCodec;
    final decoded =
        (codec.decodeMessage(codec.encodeMessage(<Object?>[clear]))!
                    as List<Object?>)
                .single!
            as AndroidStateDeltaMessage;

    expect(decoded.hasIsAtLiveEdge, isTrue);
    expect(decoded.isAtLiveEdge, isNull);
    expect(decoded.hasLiveOffsetMs, isTrue);
    expect(decoded.liveOffsetMs, isNull);
    expect(decoded.metrics!.hasManagedBufferedBytes, isTrue);
    expect(decoded.metrics!.managedBufferedBytes, isNull);
    expect(decoded.metrics!.hasReconnectCount, isTrue);
    expect(decoded.metrics!.reconnectCount, isNull);
  });

  test('Android periodic schema cannot carry static or media payload data', () {
    final schema = File(
      'packages/yl_player_android/pigeons/yl_player_android.dart',
    ).readAsStringSync();
    final deltaSchema =
        _classBlock(schema, 'AndroidStateDeltaMessage') +
        _classBlock(schema, 'AndroidMetricsDeltaMessage');

    for (final forbidden in <String>[
      'Uint8List',
      'ByteData',
      'FlutterStandardTypedData',
      'capabilities',
      'audioTracks',
      'videoTracks',
      'geometry',
      'decoderMode',
      'decoderIdentity',
      'payload',
      'mediaBytes',
    ]) {
      expect(deltaSchema, isNot(contains(forbidden)), reason: forbidden);
    }
  });
}

String _classBlock(String schema, String className) {
  final start = schema.indexOf('class $className {');
  expect(start, isNonNegative, reason: '$className is missing');
  final end = schema.indexOf('\n}', start);
  expect(end, isNonNegative, reason: '$className is unterminated');
  return schema.substring(start, end + 2);
}
