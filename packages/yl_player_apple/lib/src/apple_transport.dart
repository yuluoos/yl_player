import 'apple_codec.dart';
import 'pigeon/yl_player_apple.g.dart';

abstract interface class AppleFactoryTransport {
  Future<AppleCreateReply> create(AppleCreateRequest request);
}

abstract interface class ApplePlayerTransport {
  Future<void> attach();
  Future<AppleAssessmentReply> assess(AppleAssessRequest request);
  Future<AppleLoadReply> load(AppleLoadRequest request);
  Future<void> play(AppleSessionCommand command);
  Future<void> pause(AppleSessionCommand command);
  Future<void> seekTo(AppleSeekCommand command);
  Future<void> seekToLiveEdge(AppleSessionCommand command);
  Future<void> setPlaybackSpeed(AppleSpeedCommand command);
  Future<void> selectAudioTrack(AppleTrackCommand command);
  Future<void> setVideoConstraints(AppleVideoConstraintsCommand command);
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}

typedef AppleTransportFactory = ApplePlayerTransport Function(String suffix);
typedef AppleCallbackSetup =
    void Function(String suffix, ApplePlayerFlutterApi? callbacks);

void setupAppleCallbacks(String suffix, ApplePlayerFlutterApi? callbacks) =>
    ApplePlayerFlutterApi.setUp(callbacks, messageChannelSuffix: suffix);

Future<T> _invoke<T>(Future<T> Function() call) async {
  try {
    return await call();
  } catch (error) {
    throw AppleCodec.exception(error);
  }
}

final class PigeonAppleFactoryTransport implements AppleFactoryTransport {
  PigeonAppleFactoryTransport() : _api = ApplePlayerFactoryHostApi();
  final ApplePlayerFactoryHostApi _api;
  @override
  Future<AppleCreateReply> create(AppleCreateRequest request) =>
      _invoke(() => _api.create(request));
}

final class PigeonApplePlayerTransport implements ApplePlayerTransport {
  PigeonApplePlayerTransport(String suffix)
    : _api = ApplePlayerHostApi(messageChannelSuffix: suffix);
  final ApplePlayerHostApi _api;
  @override
  Future<void> attach() => _invoke(() => _api.attach());
  @override
  Future<AppleAssessmentReply> assess(AppleAssessRequest request) =>
      _invoke(() => _api.assess(request));
  @override
  Future<AppleLoadReply> load(AppleLoadRequest request) =>
      _invoke(() => _api.load(request));
  @override
  Future<void> play(AppleSessionCommand command) =>
      _invoke(() => _api.play(command));
  @override
  Future<void> pause(AppleSessionCommand command) =>
      _invoke(() => _api.pause(command));
  @override
  Future<void> seekTo(AppleSeekCommand command) =>
      _invoke(() => _api.seekTo(command));
  @override
  Future<void> seekToLiveEdge(AppleSessionCommand command) =>
      _invoke(() => _api.seekToLiveEdge(command));
  @override
  Future<void> setPlaybackSpeed(AppleSpeedCommand command) =>
      _invoke(() => _api.setPlaybackSpeed(command));
  @override
  Future<void> selectAudioTrack(AppleTrackCommand command) =>
      _invoke(() => _api.selectAudioTrack(command));
  @override
  Future<void> setVideoConstraints(AppleVideoConstraintsCommand command) =>
      _invoke(() => _api.setVideoConstraints(command));
  @override
  Future<void> setVolume(double volume) =>
      _invoke(() => _api.setVolume(volume));
  @override
  Future<void> stop() => _invoke(() => _api.stop());
  @override
  Future<void> dispose() => _invoke(() => _api.dispose());
}
