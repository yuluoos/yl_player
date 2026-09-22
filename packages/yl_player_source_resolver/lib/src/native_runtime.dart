import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

const _asset = 'package:yl_player_source_resolver/src/native_runtime.dart';

@Native<
  Pointer<Void> Function(
    Pointer<Utf8>,
    Size,
    Pointer<Utf8>,
    Size,
    Uint32,
    Size,
    Size,
  )
>(symbol: 'yl_js_start', assetId: _asset)
external Pointer<Void> _start(
  Pointer<Utf8> source,
  int sourceLength,
  Pointer<Utf8> parameter,
  int parameterLength,
  int timeoutMs,
  int heapBytes,
  int stackBytes,
);
@Native<Int Function(Pointer<Void>)>(symbol: 'yl_js_status', assetId: _asset)
external int _status(Pointer<Void> job);
@Native<Pointer<Utf8> Function(Pointer<Void>)>(
  symbol: 'yl_js_take_request',
  assetId: _asset,
)
external Pointer<Utf8> _takeRequest(Pointer<Void> job);
@Native<Int Function(Pointer<Void>, Pointer<Utf8>, Size, Int)>(
  symbol: 'yl_js_reply',
  assetId: _asset,
)
external int _reply(
  Pointer<Void> job,
  Pointer<Utf8> json,
  int length,
  int errorCode,
);
@Native<Pointer<Utf8> Function(Pointer<Void>)>(
  symbol: 'yl_js_result',
  assetId: _asset,
)
external Pointer<Utf8> _result(Pointer<Void> job);
@Native<Void Function(Pointer<Void>)>(symbol: 'yl_js_cancel', assetId: _asset)
external void _cancel(Pointer<Void> job);
@Native<Int Function(Pointer<Void>)>(symbol: 'yl_js_destroy', assetId: _asset)
external int _destroy(Pointer<Void> job);
@Native<Void Function(Pointer<Void>)>(symbol: 'yl_js_free', assetId: _asset)
external void _free(Pointer<Void> buffer);

/// Fixed internal failure. Never contains source, parameters or native errors.
final class NativeRuntimeException implements Exception {
  const NativeRuntimeException(this.status);
  final int status;
  @override
  String toString() => 'NativeRuntimeException($status)';
}

/// A caller-owned handle. Always await [close] (or [cancel]) in a finally block.
/// Native status is terminal only after its QuickJS context/runtime are freed.
/// No native worker ever calls into Dart.
final class NativeRuntimeJob {
  NativeRuntimeJob._(this._pointer);

  factory NativeRuntimeJob.start(
    String source, {
    String parameters = '',
    Duration timeout = const Duration(seconds: 10),
    int heapBytes = 16 * 1024 * 1024,
    int stackBytes = 512 * 1024,
  }) {
    // Character checks prevent an oversized temporary UTF8 allocation. The
    // byte checks and independent C checks remain authoritative.
    if (source.length > 512 * 1024 ||
        parameters.length > 8 * 1024 ||
        timeout.inMilliseconds < 1 ||
        timeout.inMilliseconds > 30000 ||
        heapBytes < 8 * 1024 * 1024 ||
        heapBytes > 64 * 1024 * 1024 ||
        stackBytes < 256 * 1024 ||
        stackBytes > 1024 * 1024) {
      throw const NativeRuntimeException(4);
    }
    final sourceBytes = utf8.encode(source);
    final parameterBytes = utf8.encode(parameters);
    if (sourceBytes.length > 512 * 1024 || parameterBytes.length > 8 * 1024) {
      throw const NativeRuntimeException(4);
    }
    return withNativeInputBuffers(source, parameters, (
      sourcePointer,
      parameterPointer,
    ) {
      final pointer = _start(
        sourcePointer,
        sourceBytes.length,
        parameterPointer,
        parameterBytes.length,
        timeout.inMilliseconds,
        heapBytes,
        stackBytes,
      );
      if (pointer == nullptr) throw const NativeRuntimeException(4);
      return NativeRuntimeJob._(pointer);
    });
  }

  Pointer<Void> _pointer;
  int _finalStatus = 0;
  bool _cancelled = false;
  Future<void>? _closing;

  int get status {
    final value = _pointer == nullptr ? _finalStatus : _status(_pointer);
    return _cancelled && value != 0 ? 3 : value;
  }

  String? get resultJson {
    if (_pointer == nullptr || _cancelled) return null;
    return _copyAndFree(_result(_pointer));
  }

  String? takeRequest() {
    if (_pointer == nullptr || _cancelled) return null;
    return _copyAndFree(_takeRequest(_pointer));
  }

  bool reply(String json, {int errorCode = 0}) {
    if (_pointer == nullptr || _cancelled) return false;
    // Reject before allocating unbounded FFI storage; native independently
    // enforces the response budget for all accepted replies.
    if (json.length > 1024 * 1024) {
      return _reply(_pointer, nullptr, 1024 * 1024 + 1, 0) != 0;
    }
    final bytes = utf8.encode(json);
    if (bytes.length > 1024 * 1024) {
      return _reply(_pointer, nullptr, bytes.length, 0) != 0;
    }
    final pointer = json.toNativeUtf8();
    try {
      return _reply(_pointer, pointer, bytes.length, errorCode) != 0;
    } finally {
      malloc.free(pointer);
    }
  }

  /// Idempotent cancellation includes native VM cleanup and worker joining.
  Future<void> cancel() {
    _cancelled = true;
    if (_pointer != nullptr) _cancel(_pointer);
    return close();
  }

  /// Cancels a still-running job and reclaims its caller-owned native handle.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_pointer == nullptr) return;
    if (_status(_pointer) == 0) {
      _cancelled = true;
      _cancel(_pointer);
    }
    while (_status(_pointer) == 0) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    _finalStatus = _status(_pointer);
    if (_destroy(_pointer) != 1) throw const NativeRuntimeException(6);
    _pointer = nullptr;
  }

  static String? _copyAndFree(Pointer<Utf8> pointer) {
    if (pointer == nullptr) return null;
    try {
      return pointer.toDartString();
    } finally {
      _free(pointer.cast());
    }
  }

  @override
  String toString() => 'NativeRuntimeJob(status: $status)';
}

/// Runs a synchronous native input consumer with temporary owned UTF8 buffers.
/// The allocator is injectable at this internal ownership boundary.
R withNativeInputBuffers<R>(
  String source,
  String parameters,
  R Function(Pointer<Utf8> source, Pointer<Utf8> parameters) consume, {
  Allocator allocator = malloc,
}) {
  return using((arena) {
    final sourcePointer = source.toNativeUtf8(allocator: arena);
    final parameterPointer = parameters.toNativeUtf8(allocator: arena);
    return consume(sourcePointer, parameterPointer);
  }, allocator);
}
