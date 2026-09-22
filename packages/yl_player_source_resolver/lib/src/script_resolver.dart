import 'dart:async';
import 'dart:convert';

import 'native_runtime.dart';
import 'script_http.dart';
import 'script_models.dart';

/// A resolution owns its transport and native VM until its result settles.
final class YlScriptResolution {
  YlScriptResolution._(this._limits, this._onDone);

  final YlScriptLimits _limits;
  final void Function(YlScriptResolution) _onDone;
  final _result = Completer<YlResolvedSource>();
  final _cleaned = Completer<void>();
  final _clock = Stopwatch();
  final String _diagnosticId = createScriptDiagnosticId();
  String _phase = 'input';
  ScriptHttp? _http;
  NativeRuntimeJob? _native;
  Timer? _timer;
  YlScriptException? _stop;
  bool _done = false;

  Future<YlResolvedSource> get result => _result.future;
  String get diagnosticId => _diagnosticId;

  Future<void> cancel() {
    if (!_done) _interrupt(scriptFailure('cancelled'));
    return _cleaned.future;
  }

  void _interrupt(YlScriptException reason) {
    _stop ??= reason;
    // First abort transport. The execution loop awaits its settlement and then
    // reclaims the native handle; native deadline also wakes its host wait.
    _http?.abort();
  }

  void _checkStopped() {
    if (_stop != null) throw _stop!;
    if (_clock.elapsed >= _limits.timeout) {
      _interrupt(scriptFailure('timeout'));
      throw _stop!;
    }
  }

  Future<void> _run(
    String? source,
    String parameters,
    YlScriptReference? reference, {
    YlScriptException? initialError,
  }) async {
    YlResolvedSource? resolved;
    YlScriptException? failure;
    _clock.start();
    try {
      if (initialError != null) throw initialError;
      checkScriptBytes(parameters, 8192);
      if (source != null) checkScriptBytes(source, 524288);
      _checkStopped();
      _http = ScriptHttp();
      _timer = Timer(
        _limits.timeout,
        () => _interrupt(scriptFailure('timeout')),
      );
      if (source == null) {
        _phase = 'download';
        source = await _http!.download(reference!);
      }
      _checkStopped();
      final remaining = _limits.timeout - _clock.elapsed;
      if (remaining.inMilliseconds < 1) throw scriptFailure('timeout');
      _phase = 'evaluation';
      final native = _native = NativeRuntimeJob.start(
        source,
        parameters: parameters,
        timeout: remaining,
        heapBytes: _limits.heapBytes,
        stackBytes: _limits.stackBytes,
      );
      while (native.status == 0) {
        _checkStopped();
        final request = native.takeRequest();
        if (request != null) {
          _phase = 'host';
          final reply = await _http!.host(request);
          _checkStopped();
          if (!native.reply(jsonEncode(reply))) {
            _checkStopped();
            throw _nativeFailure(native.status);
          }
          _phase = 'evaluation';
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
      }
      _checkStopped();
      if (native.status != 1) throw _nativeFailure(native.status);
      _phase = 'result';
      resolved = normalizeScriptResult(native.resultJson);
    } on YlScriptException catch (error) {
      failure = error;
    } on NativeRuntimeException catch (error) {
      failure = _nativeFailure(error.status);
    } on Object {
      failure = scriptFailure('execution');
    } finally {
      _http?.abort();
      try {
        await _native?.close();
      } on Object {
        failure ??= scriptFailure('execution');
      }
      _timer?.cancel();
      _clock.stop();
      failure = _stop ?? failure;
      _done = true;
      _onDone(this);
      if (failure != null) {
        _result.completeError(
          withScriptFailureContext(failure, _diagnosticId, _phase),
        );
      } else {
        _result.complete(resolved!);
      }
      _cleaned.complete();
    }
  }

  @override
  String toString() => 'YlScriptResolution(<redacted>)';
}

YlScriptException _nativeFailure(int status) => scriptFailure(switch (status) {
  2 => 'timeout',
  3 => 'cancelled',
  4 => 'resource_limit',
  5 => 'syntax',
  7 => 'host_api_unsupported',
  8 => 'invalid_result',
  9 => 'transport',
  _ => 'execution',
});

final class YlScriptResolver {
  YlScriptResolver({YlScriptLimits limits = const YlScriptLimits()})
    : _limits = limits {
    limits.validate();
  }

  final YlScriptLimits _limits;
  final Set<YlScriptResolution> _active = {};
  bool _disposed = false;
  Future<void>? _disposing;

  YlScriptResolution resolve(YlScriptReference reference) =>
      _start(null, reference.parameters, reference);

  YlScriptResolution resolveSource(String source, {String parameters = ''}) =>
      _start(source, parameters, null);

  YlScriptResolution _start(
    String? source,
    String parameters,
    YlScriptReference? reference,
  ) {
    final resolution = YlScriptResolution._(_limits, _active.remove);
    final error = _disposed
        ? scriptFailure('disposed')
        : _active.length >= 4
        ? scriptFailure('resource_limit')
        : null;
    _active.add(resolution);
    unawaited(
      resolution._run(source, parameters, reference, initialError: error),
    );
    return resolution;
  }

  Future<void> dispose() {
    _disposed = true;
    return _disposing ??= Future.wait(
      _active.toList().map((job) => job.cancel()),
    );
  }
}
