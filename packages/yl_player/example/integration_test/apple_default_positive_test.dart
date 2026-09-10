// Focused evaluation of the formerly error-accepting default-policy iOS helpers.
import 'ios_mkv_playback_test.dart' as local;
import 'ios_network_mkv_playback_test.dart' as network;
import 'ios_http_flv_playback_test.dart' as live;

void main() {
  local.main();
  network.main();
  live.main();
}
