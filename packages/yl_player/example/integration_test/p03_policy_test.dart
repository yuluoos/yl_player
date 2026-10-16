import 'opus_policy_test.dart' as opus;
import 'vorbis_policy_test.dart' as vorbis;
import 'vp9_policy_test.dart' as vp9;

/// Run the affected public codec-policy regressions in one product build.
void main() {
  opus.main();
  vorbis.main();
  vp9.main();
}
