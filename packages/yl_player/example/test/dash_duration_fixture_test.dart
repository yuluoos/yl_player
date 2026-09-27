import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/dash_duration_fixture.dart';

void main() {
  test('duration fixture removes only MPD total and final Period duration', () {
    const input =
        '<MPD mediaPresentationDuration="PT8S"><Period start="PT0S" duration="PT4S"><SegmentTemplate duration="2"/></Period><Period start="PT4S" duration="PT4S"><SegmentTemplate duration="2"/></Period></MPD>';
    const expected =
        '<MPD><Period start="PT0S" duration="PT4S"><SegmentTemplate duration="2"/></Period><Period start="PT4S"><SegmentTemplate duration="2"/></Period></MPD>';
    expect(omitFinalDashDuration(input), expected);
  });
}
