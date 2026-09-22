import 'package:flutter_test/flutter_test.dart';
import 'package:yl_player_source_resolver/yl_player_source_resolver.dart';

void main() {
  test('reference parser preserves raw query spelling and plus', () {
    final reference = YlScriptReference.parse(
      'javascript://https://fixture.invalid/a.js?id=a%2fb+z&x=a=b',
    );
    expect(reference.scriptUri.toString(), 'https://fixture.invalid/a.js');
    expect(reference.parameters, 'id=a%2fb+z&x=a=b');
    expect(reference.toString(), isNot(contains('fixture.invalid')));
  });
  test('reference rejects unsafe transport and parameters', () {
    for (final url in [
      'file:///a',
      'https://user:SECRET@fixture.invalid/a',
      'https://fixture.invalid/a#fragment',
    ]) {
      expect(
        () => YlScriptReference(scriptUri: Uri.parse(url), parameters: ''),
        throwsA(isA<YlScriptException>()),
      );
    }
    expect(
      () => YlScriptReference(
        scriptUri: Uri.parse('https://fixture.invalid'),
        parameters: 'x' * 8193,
      ),
      throwsA(isA<YlScriptException>()),
    );
  });
}
