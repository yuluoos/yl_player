// One build/launch for the strict policy suite. Individual files stay runnable.
import 'apple_managed_network_test.dart' as network;
import 'apple_bounded_buffer_test.dart' as buffer;
import 'apple_hardware_required_test.dart' as hardware;
import 'apple_session_replacement_test.dart' as replacement;
import 'apple_audio_policy_test.dart' as audio;

void main() {
  network.main();
  buffer.main();
  hardware.main();
  replacement.main();
  audio.main();
}
