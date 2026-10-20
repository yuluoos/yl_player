import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'subtitle_playback_test.dart' as subtitles;
import 'subtitle_completed_seek_test.dart' as completed;
import 'apple_dash_audio_tracks_test.dart' as audio;
import 'p02_device_observation_test.dart' as observation;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  completed.main();
  subtitles.main();
  audio.main();
  observation.main();
}
