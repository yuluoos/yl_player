import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_source_resolver/src/script_http.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';

void main() {
  void verify(YlScriptResolution resolution) {
    expect(resolution.timings, isNotNull);
    final times = resolution.timings!;
    expect(
      times['total']!.inMicroseconds,
      times.entries
          .where((e) => e.key != 'total')
          .fold<int>(0, (sum, e) => sum + (e.value?.inMicroseconds ?? 0)),
    );
    expect(
      times.values.whereType<Duration>().every((d) => !d.isNegative),
      isTrue,
    );
    expect(() => times['host'] = Duration.zero, throwsUnsupportedError);
  }

  test(
    'real native evaluation and cleanup retain exact non-overlapping wall phases',
    () async {
      final resolver = YlScriptResolver();
      addTearDown(resolver.dispose);
      final job = resolver.resolveSource(
        'function main(){return {url:"https://fixture.invalid/SECRET"}}',
      );
      expect(job.timings, isNull);
      await job.result;
      verify(job);
      expect(job.timings!['evaluation'], isNotNull);
      expect(job.timings!['download'], isNull);
      expect(job.timings!['host'], isNull);
      expect(job.timings!['cleanup'], isNotNull);
      expect(job.timings.toString(), isNot(contains('SECRET')));
    },
  );
  test(
    'failed syntax keeps partial phase timings and does not invent result phase',
    () async {
      final resolver = YlScriptResolver();
      addTearDown(resolver.dispose);
      final job = resolver.resolveSource('function broken(');
      await expectLater(job.result, throwsA(isA<YlScriptException>()));
      verify(job);
      expect(job.timings!['result'], isNull);
    },
  );
  test('real host requests separate waits from evaluation', () async {
    final resolver = YlScriptResolver();
    addTearDown(resolver.dispose);
    await withScriptHttpFixture(
      (uri, method, headers, body) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return ScriptHttpReply(200, [111, 107]);
      },
      () async {
        final job = resolver.resolveSource(
          'function main(){mytv.get("https://fixture.invalid");return {url:"https://fixture.invalid/video"}}',
        );
        await job.result;
        verify(job);
        expect(job.timings!['host']!.inMilliseconds, greaterThanOrEqualTo(20));
      },
    );
  });
  test('source download wall time is separate from VM evaluation', () async {
    final resolver = YlScriptResolver();
    addTearDown(resolver.dispose);
    await withScriptHttpFixture(
      (uri, method, headers, body) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return ScriptHttpReply(
          200,
          utf8.encode(
            'function main(){return {url:"https://fixture.invalid/video"}}',
          ),
        );
      },
      () async {
        final job = resolver.resolve(
          YlScriptReference(
            scriptUri: Uri.parse('https://fixture.invalid/owned.js'),
            parameters: '',
          ),
        );
        await job.result;
        verify(job);
        expect(
          job.timings!['download']!.inMilliseconds,
          greaterThanOrEqualTo(20),
        );
        expect(job.timings!['evaluation'], isNotNull);
        expect(job.timings!['host'], isNull);
      },
    );
  });
}
