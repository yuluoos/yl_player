import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_source_resolver/src/native_runtime.dart';

Future<int> finished(NativeRuntimeJob job) async {
  while (job.status == 0) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  return job.status;
}

Future<String> request(NativeRuntimeJob job) async {
  for (var i = 0; i < 1000; i++) {
    final value = job.takeRequest();
    if (value != null) return value;
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  fail('Native host request was not produced');
}

void main() {
  test('frees source input when parameter allocation fails', () {
    final allocator = _FailSecondAllocator();
    addTearDown(allocator.releaseOutstanding);
    var consumed = false;
    expect(
      () => withNativeInputBuffers('source', 'parameter', (_, _) {
        consumed = true;
      }, allocator: allocator),
      throwsArgumentError,
    );
    expect(allocator.attempts, 2);
    expect(consumed, isFalse);
    expect(allocator.outstanding, isEmpty);
  });
  test(
    'real runtime returns main result and preserves parameter bytes',
    () async {
      final job = NativeRuntimeJob.start(
        'function main(p){return {url:p}}',
        parameters: 'x=a%2Fb&x=1+2',
      );
      addTearDown(job.close);
      expect(await finished(job), 1);
      expect(jsonDecode(job.resultJson!), {'url': 'x=a%2Fb&x=1+2'});
    },
  );
  test('native deadline terminates infinite JavaScript', () async {
    final job = NativeRuntimeJob.start(
      'while(true){}',
      timeout: const Duration(milliseconds: 100),
    );
    addTearDown(job.close);
    expect(await finished(job), 2);
    expect(job.resultJson, isNull);
  });
  test('cancel awaits destruction and is safe to repeat', () async {
    final job = NativeRuntimeJob.start('function main(){while(true){}}');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await job.cancel();
    await job.cancel();
    await job.close();
    expect(job.status, 3);
    expect(job.resultJson, isNull);
  });
  test('synchronous host request receives a bounded JSON reply', () async {
    final job = NativeRuntimeJob.start(
      "function main(){return {url:mytv.get('https://example.invalid')}}",
    );
    addTearDown(job.close);
    expect(jsonDecode(await request(job)), {
      'method': 'get',
      'args': ['https://example.invalid'],
    });
    expect(job.takeRequest(), isNull);
    expect(job.reply(jsonEncode('https://example.invalid/media')), isTrue);
    expect(await finished(job), 1);
    expect(jsonDecode(job.resultJson!), {
      'url': 'https://example.invalid/media',
    });
  });
  test('cancel wakes a held synchronous host request', () async {
    final job = NativeRuntimeJob.start(
      "function main(){return mytv.get('https://example.invalid')}",
    );
    await request(job);
    await job.cancel();
    expect(job.status, 3);
    expect(job.reply('null'), isFalse);
  });
  test(
    'JavaScript errors remain fixed status with no secret payload',
    () async {
      final job = NativeRuntimeJob.start(
        "function main(){throw new Error('SECRET-credential')}",
      );
      addTearDown(job.close);
      expect(await finished(job), 6);
      expect(job.resultJson, isNull);
      expect(job.toString(), isNot(contains('SECRET')));
    },
  );
  test('async main drains Promise work in the same runtime', () async {
    final job = NativeRuntimeJob.start(
      "async function main(){await Promise.resolve();return {url:'https://example.invalid'}}",
    );
    addTearDown(job.close);
    expect(await finished(job), 1);
    expect(jsonDecode(job.resultJson!), {'url': 'https://example.invalid'});
  });
}

// Test-only allocator that allocates real native storage and fails the second
// acquisition deterministically, without putting the host under memory pressure.
final class _FailSecondAllocator implements Allocator {
  int attempts = 0;
  final outstanding = <Pointer<NativeType>>{};

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    if (++attempts == 2) throw ArgumentError('Synthetic allocation failure');
    final pointer = malloc.allocate<T>(byteCount, alignment: alignment);
    outstanding.add(pointer);
    return pointer;
  }

  @override
  void free(Pointer<NativeType> pointer) {
    outstanding.remove(pointer);
    malloc.free(pointer);
  }

  void releaseOutstanding() {
    for (final pointer in outstanding.toList()) {
      free(pointer);
    }
  }
}
