import 'package:flutter/foundation.dart';

import '../validation/state_validation.dart';
import 'capabilities.dart';
import 'failure.dart';
import 'value_helpers.dart';

enum YlSourceAssessmentOutcome { compatible, incompatible, requiresInspection }

const _absent = Object();

/// Immutable SourceAssessment value; validate at publication boundaries.
final class YlSourceAssessment {
  YlSourceAssessment({
    required this.outcome,
    this.candidateEngine,
    List<YlRequirementId> satisfiedRequirements = const [],
    List<YlLimitationId> limitations = const [],
    this.rejection,
  }) : satisfiedRequirements = List.unmodifiable(satisfiedRequirements),
       limitations = List.unmodifiable(limitations) {
    validateYlSourceAssessment(this);
  }

  final YlSourceAssessmentOutcome outcome;

  final YlPlaybackEngine? candidateEngine;

  final List<YlRequirementId> satisfiedRequirements;

  final List<YlLimitationId> limitations;

  final YlFailure? rejection;

  /// Omitted fields are preserved; explicit null clears nullable fields.
  YlSourceAssessment copyWith({
    YlSourceAssessmentOutcome? outcome,
    Object? candidateEngine = _absent,
    List<YlRequirementId>? satisfiedRequirements,
    List<YlLimitationId>? limitations,
    Object? rejection = _absent,
  }) => YlSourceAssessment(
    outcome: outcome ?? this.outcome,
    candidateEngine: identical(candidateEngine, _absent)
        ? this.candidateEngine
        : ylNullableValue<YlPlaybackEngine>(candidateEngine),
    satisfiedRequirements: satisfiedRequirements ?? this.satisfiedRequirements,
    limitations: limitations ?? this.limitations,
    rejection: identical(rejection, _absent)
        ? this.rejection
        : ylNullableValue<YlFailure>(rejection),
  );

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        outcome == other.outcome &&
        candidateEngine == other.candidateEngine &&
        listEquals(satisfiedRequirements, other.satisfiedRequirements) &&
        listEquals(limitations, other.limitations) &&
        rejection == other.rejection,
  );

  @override
  int get hashCode => Object.hashAll([
    outcome,
    candidateEngine,
    Object.hashAll(satisfiedRequirements),
    Object.hashAll(limitations),
    rejection,
  ]);

  @override
  String toString() =>
      'YlSourceAssessment(outcome: $outcome, candidateEngine: $candidateEngine, satisfiedRequirements: $satisfiedRequirements, limitations: $limitations, rejection: $rejection)';
}

// Preserve documented camelCase wire values; require bounded ASCII segments.
final _assessmentId = RegExp(r'^[a-z][A-Za-z0-9]*(?:[._-][A-Za-z0-9]+)+$');
void _validateAssessmentId(String value) {
  final match = _assessmentId.firstMatch(value);
  if (value.length > 128 || match == null || match.end != value.length) {
    throw ArgumentError('Assessment identifier is invalid.');
  }
}

/// Extensible, validated wire identifier; diagnostics never echo its value.
final class YlRequirementId {
  YlRequirementId(this.value) {
    _validateAssessmentId(value);
  }
  const YlRequirementId._(this.value);
  final String value;
  static const networkPlatformDefault = YlRequirementId._(
    'network.platformDefault',
  );
  static const networkManaged = YlRequirementId._('network.managed');
  static const bufferAutomatic = YlRequirementId._('buffer.automatic');
  static const bufferLowLatency = YlRequirementId._('buffer.lowLatency');
  static const bufferSmoothPlayback = YlRequirementId._(
    'buffer.smoothPlayback',
  );
  static const bufferBounded = YlRequirementId._('buffer.bounded');
  static const decoderSystemDefault = YlRequirementId._(
    'decoder.systemDefault',
  );
  static const decoderHardwarePreferred = YlRequirementId._(
    'decoder.hardwarePreferred',
  );
  static const decoderHardwareRequired = YlRequirementId._(
    'decoder.hardwareRequired',
  );
  @override
  bool operator ==(Object other) =>
      ylValueEquals(this, other, (other) => value == other.value);
  @override
  int get hashCode => Object.hash(YlRequirementId, value);
  @override
  String toString() => 'YlRequirementId(<redacted>)';
}

/// Extensible, validated wire identifier; diagnostics never echo its value.
final class YlLimitationId {
  YlLimitationId(this.value) {
    _validateAssessmentId(value);
  }
  const YlLimitationId._(this.value);
  final String value;
  static const sourceRequiresInspection = YlLimitationId._(
    'source.requiresInspection',
  );
  static const codecRequiresInspection = YlLimitationId._(
    'codec.requiresInspection',
  );
  static const decoderModeUnknown = YlLimitationId._('decoder.modeUnknown');
  static const bufferOsMemoryExcluded = YlLimitationId._(
    'buffer.osMemoryExcluded',
  );
  static const networkSystemStackOpaque = YlLimitationId._(
    'network.systemStackOpaque',
  );
  @override
  bool operator ==(Object other) =>
      ylValueEquals(this, other, (other) => value == other.value);
  @override
  int get hashCode => Object.hash(YlLimitationId, value);
  @override
  String toString() => 'YlLimitationId(<redacted>)';
}
