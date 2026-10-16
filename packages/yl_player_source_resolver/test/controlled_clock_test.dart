import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';
import 'support/controlled_contract.dart';

void main() {
  test(
    'JS07 fixture pins ambient clock while preserving Date operations',
    () async {
      final resolver = YlScriptResolver();
      addTearDown(resolver.dispose);
      final result = await resolver
          .resolveSource(
            controlledScriptSource('JS-07', '''
function main() {
 const epoch=Date.UTC(2026,8,22,12);
 if(Date.now()!==epoch || +new Date()!==epoch || +new Date(123)!==123 ||
    Date.parse('2026-09-22T12:00:00Z')!==epoch ||
    typeof Date()!=='string' || !(new Date() instanceof Date)) throw Error('clock');
 return {url:'https://fixture.invalid/clock.m3u8'};
}
'''),
          )
          .result;
      expect(result.uri.path, '/clock.m3u8');
    },
  );
  test('other frozen scripts retain their original execution bytes', () {
    for (final id in frozenScripts.keys.where((id) => id != 'JS-07')) {
      expect(controlledScriptSource(id, 'original'), 'original');
    }
  });
}
