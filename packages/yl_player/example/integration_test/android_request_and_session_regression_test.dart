// Run the public request, cancellation and callback regressions in one APK.
import 'android_dash_playback_test.dart' as dash;
import 'android_hls_playback_test.dart' as hls;
import 'android_managed_fault_isolation_test.dart' as faults;
import 'android_session_replacement_test.dart' as replacement;
import 'dash_candidate_playback_test.dart' as candidates;
import 'dash_program_cancellation_test.dart' as cancellation;

void main() {
  hls.main();
  dash.main();
  candidates.main();
  faults.main();
  replacement.main();
  cancellation.main();
}
