import 'package:flutter_test/flutter_test.dart';
import '../integration_test/support/display_markers.dart';

Map<String, Object?> sample(List<int>? rgb) => {
  'status': rgb == null ? 'noImage' : 'observed',
  'layerCount': 1,
  'ready': rgb != null,
  'width': rgb == null ? null : 320,
  'height': rgb == null ? null : 180,
  'pixels': rgb == null ? null : List.generate(27, (i) => rgb[i % 3]),
  'colorMetadata': rgb == null
      ? null
      : {
          'matrix': 'bt709',
          'primaries': 'bt709',
          'transfer': 'bt709',
          'rgbColorSpace': 'coreMedia709',
        },
};
void main() {
  test(
    'unknown primaries retain pixels but cannot qualify an sRGB reference',
    () {
      final markers = DisplayMarkers(startedUs: 0);
      final row = sample([248, 36, 0]);
      row['colorMetadata'] = {
        'matrix': 'bt601',
        'primaries': 'unspecified',
        'transfer': 'bt709',
        'rgbColorSpace': 'other',
      };
      expect(
        () => markers.observe(row, 1),
        throwsA(isA<DisplayReferenceUnavailable>()),
      );
      expect(markers.observations.single['pixels'], row['pixels']);
      expect(markers.observations.single['marker'], isNull);
      expect(markers.complete, isFalse);
    },
  );
  test(
    'BT601 matrix with explicit BT709 primaries is a qualified reference',
    () {
      final markers = DisplayMarkers(startedUs: 0);
      final row = sample([254, 0, 0]);
      row['colorMetadata'] = {
        'matrix': 'bt601',
        'primaries': 'bt709',
        'transfer': 'bt709',
        'rgbColorSpace': 'coreMedia709',
      };
      markers.observe(row, 1);
      expect(markers.markersSeen, 1);
    },
  );
  test(
    'explicit other primaries and missing metadata cannot silently pass',
    () {
      for (final primaries in ['smpteC', 'missing', 'other']) {
        final row = sample([255, 0, 0]);
        row['colorMetadata'] = {
          'matrix': 'bt601',
          'primaries': primaries,
          'transfer': 'bt709',
          'rgbColorSpace': 'coreMedia709',
        };
        expect(
          () => DisplayMarkers(startedUs: 0).observe(row, 1),
          throwsA(isA<DisplayReferenceUnavailable>()),
        );
      }
      expect(
        () => DisplayMarkers(startedUs: 0).observe({
          ...sample([255, 0, 0]),
          'colorMetadata': null,
        }, 1),
        throwsFormatException,
      );
    },
  );
  test('normalized primaries require a resolved Core Media 709 space', () {
    for (final matrix in ['bt601', 'bt709']) {
      final row = sample([255, 0, 0]);
      row['colorMetadata'] = {
        'matrix': matrix,
        'primaries': 'unspecified',
        'transfer': 'bt709',
        'rgbColorSpace': 'coreMedia709',
      };
      final markers = DisplayMarkers(startedUs: 0)..observe(row, 1);
      expect(markers.markersSeen, 1);
    }
    for (final space in ['srgb', 'other', 'missing']) {
      final row = sample([255, 0, 0]);
      row['colorMetadata'] = {
        'matrix': 'bt709',
        'primaries': 'bt709',
        'transfer': 'bt709',
        'rgbColorSpace': space,
      };
      expect(
        () => DisplayMarkers(startedUs: 0).observe(row, 1),
        throwsA(isA<DisplayReferenceUnavailable>()),
      );
    }
  });
  test(
    'requires all four ordered displayed colors and retains polling bounds',
    () {
      final markers = DisplayMarkers(startedUs: 100);
      markers.observe(sample(null), 110);
      markers.observe(sample([250, 3, 2]), 120);
      markers.observe(sample([255, 0, 0]), 140);
      markers.observe(sample([0, 255, 0]), 180);
      markers.observe(sample([0, 0, 255]), 220);
      expect(markers.complete, isFalse);
      markers.observe(sample([255, 255, 255]), 260);
      expect(markers.complete, isTrue);
      expect(markers.firstReadbackUs, 120);
      expect(markers.firstReadbackDelayUs, 20);
      expect(markers.observations, hasLength(6));
    },
  );
  test('black, stale initial blue, and skipped color cannot pass', () {
    final blank = DisplayMarkers(startedUs: 0);
    blank.observe(sample([0, 0, 0]), 1);
    expect(blank.complete, isFalse);
    final stale = DisplayMarkers(startedUs: 0);
    expect(() => stale.observe(sample([0, 0, 255]), 1), throwsStateError);
    final skipped = DisplayMarkers(startedUs: 0);
    skipped.observe(sample([255, 0, 0]), 1);
    expect(() => skipped.observe(sample([0, 0, 255]), 2), throwsStateError);
  });
  test('validates all nine patches and exact schema before retaining data', () {
    final markers = DisplayMarkers(startedUs: 0);
    final row = sample([255, 0, 0]);
    (row['pixels'] as List<int>)[24] = 0;
    markers.observe(row, 1);
    expect(markers.firstReadbackUs, isNull);
    expect(
      () => markers.observe({...sample(null), 'private': 'value'}, 2),
      throwsFormatException,
    );
    expect(
      () => markers.observe({...sample(null), 'status': 'observed'}, 2),
      throwsFormatException,
    );
    expect(() => markers.observe(sample(null), 1), throwsStateError);
  });
  test(
    'native missing/ambiguous output cannot become a passed observation',
    () {
      final markers = DisplayMarkers(startedUs: 0);
      expect(
        () => markers.observe({...sample(null), 'status': 'ambiguous'}, 1),
        throwsStateError,
      );
    },
  );
}
