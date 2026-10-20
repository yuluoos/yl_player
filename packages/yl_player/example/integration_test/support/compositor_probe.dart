import 'dart:convert';
import 'dart:ffi';

/// Test-only own-window capture. All timings use the probe's mach host clock.
final class CompositorProbe {
  CompositorProbe(String path) : _library = DynamicLibrary.open(path);
  final DynamicLibrary _library;
  late final visibility = _library
      .lookupFunction<Void Function(Int32), void Function(int)>(
        'yl_capture_visibility',
      );
  late final nowUs = _library.lookupFunction<Uint64 Function(), int Function()>(
    'yl_capture_clock_us',
  );
  late final start = _library.lookupFunction<Void Function(), void Function()>(
    'yl_capture_start',
  );
  late final stop = _library.lookupFunction<Void Function(), void Function()>(
    'yl_capture_stop',
  );
  late final _snapshot = _library
      .lookupFunction<Pointer<Uint8> Function(), Pointer<Uint8> Function()>(
        'yl_capture_snapshot',
      );
  late final _free = _library
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('yl_capture_free');
  Map<String, dynamic> snapshot() {
    final pointer = _snapshot();
    if (pointer == nullptr) throw const FormatException('Capture unavailable');
    try {
      final bytes = <int>[];
      for (var i = 0; i < 1024 * 1024; i++) {
        final value = pointer[i];
        if (value == 0) {
          return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        }
        bytes.add(value);
      }
      throw const FormatException('Capture observation limit');
    } finally {
      _free(pointer);
    }
  }
}
