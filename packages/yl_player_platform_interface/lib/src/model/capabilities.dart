import 'package:flutter/foundation.dart';

import '../validation/state_validation.dart';
import 'value_helpers.dart';

enum YlPlaybackStatus {
  idle,
  loading,
  ready,
  playing,
  paused,
  buffering,
  completed,
  failed,
}

enum YlPlaybackEngine { unknown, media3, avPlayer, managedFallback }

enum YlDecoderMode { unknown, hardware, software }

enum YlDecoderEvidence { none, hardwareOnly, hardwareAndSoftware }

enum YlPlayerOperation {
  seek,
  seekToLiveEdge,
  playbackSpeed,
  audioTrackSelection,
  videoConstraints,
  volume,
  stop,
}

const _absent = Object();

/// Immutable PlayerCapabilities value; validate at publication boundaries.
final class YlPlayerCapabilities {
  YlPlayerCapabilities({
    required this.deviceProfile,
    List<YlPlaybackEngine> availableEngines = const [],
    List<YlPlayerOperation> supportedOperations = const [],
    this.decoderEvidence = YlDecoderEvidence.none,
    List<String> hardwareVideoCodecs = const [],
    this.maxConcurrentVideoDecoders,
    this.maxWidth,
    this.maxHeight,
  }) : availableEngines = List.unmodifiable(availableEngines),
       supportedOperations = List.unmodifiable(supportedOperations),
       hardwareVideoCodecs = List.unmodifiable(hardwareVideoCodecs) {
    validateYlPlayerCapabilities(this);
  }

  final String deviceProfile;

  final List<YlPlaybackEngine> availableEngines;

  final List<YlPlayerOperation> supportedOperations;

  final YlDecoderEvidence decoderEvidence;

  final List<String> hardwareVideoCodecs;

  final int? maxConcurrentVideoDecoders;

  final int? maxWidth;

  final int? maxHeight;

  /// Omitted fields are preserved; explicit null clears nullable fields.
  YlPlayerCapabilities copyWith({
    String? deviceProfile,
    List<YlPlaybackEngine>? availableEngines,
    List<YlPlayerOperation>? supportedOperations,
    YlDecoderEvidence? decoderEvidence,
    List<String>? hardwareVideoCodecs,
    Object? maxConcurrentVideoDecoders = _absent,
    Object? maxWidth = _absent,
    Object? maxHeight = _absent,
  }) => YlPlayerCapabilities(
    deviceProfile: deviceProfile ?? this.deviceProfile,
    availableEngines: availableEngines ?? this.availableEngines,
    supportedOperations: supportedOperations ?? this.supportedOperations,
    decoderEvidence: decoderEvidence ?? this.decoderEvidence,
    hardwareVideoCodecs: hardwareVideoCodecs ?? this.hardwareVideoCodecs,
    maxConcurrentVideoDecoders: identical(maxConcurrentVideoDecoders, _absent)
        ? this.maxConcurrentVideoDecoders
        : ylNullableValue<int>(maxConcurrentVideoDecoders),
    maxWidth: identical(maxWidth, _absent)
        ? this.maxWidth
        : ylNullableValue<int>(maxWidth),
    maxHeight: identical(maxHeight, _absent)
        ? this.maxHeight
        : ylNullableValue<int>(maxHeight),
  );

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        deviceProfile == other.deviceProfile &&
        listEquals(availableEngines, other.availableEngines) &&
        listEquals(supportedOperations, other.supportedOperations) &&
        decoderEvidence == other.decoderEvidence &&
        listEquals(hardwareVideoCodecs, other.hardwareVideoCodecs) &&
        maxConcurrentVideoDecoders == other.maxConcurrentVideoDecoders &&
        maxWidth == other.maxWidth &&
        maxHeight == other.maxHeight,
  );

  @override
  int get hashCode => Object.hashAll([
    deviceProfile,
    Object.hashAll(availableEngines),
    Object.hashAll(supportedOperations),
    decoderEvidence,
    Object.hashAll(hardwareVideoCodecs),
    maxConcurrentVideoDecoders,
    maxWidth,
    maxHeight,
  ]);

  @override
  String toString() =>
      'YlPlayerCapabilities(deviceProfile: $deviceProfile, availableEngines: $availableEngines, supportedOperations: $supportedOperations, decoderEvidence: $decoderEvidence, hardwareVideoCodecs: $hardwareVideoCodecs, maxConcurrentVideoDecoders: $maxConcurrentVideoDecoders, maxWidth: $maxWidth, maxHeight: $maxHeight)';
}
