import 'android_codec.dart';
import 'pigeon/yl_player_android.g.dart';

abstract interface class AndroidFactoryTransport {
  Future<AndroidCreateReply> create(AndroidCreateRequest request);
}

abstract interface class AndroidPlayerTransport {
  Future<void> attach();
  Future<AndroidAssessmentReply> assess(AndroidAssessRequest request);
  Future<AndroidLoadReply> load(AndroidLoadRequest request);
  Future<void> play(AndroidSessionCommand command);
  Future<void> pause(AndroidSessionCommand command);
  Future<void> seekTo(AndroidSeekCommand command);
  Future<void> seekToLiveEdge(AndroidSessionCommand command);
  Future<void> setPlaybackSpeed(AndroidSpeedCommand command);
  Future<void> selectAudioTrack(AndroidTrackCommand command);
  Future<void> setVideoConstraints(AndroidVideoConstraintsCommand command);
  Future<void> setVolume(double volume);
  Future<void> stop();
  Future<void> dispose();
}

typedef AndroidTransportFactory =
    AndroidPlayerTransport Function(String suffix);
typedef AndroidCallbackSetup =
    void Function(String suffix, AndroidPlayerFlutterApi? callbacks);

void setupAndroidCallbacks(String suffix, AndroidPlayerFlutterApi? callbacks) =>
    AndroidPlayerFlutterApi.setUp(callbacks, messageChannelSuffix: suffix);

Future<T> _invoke<T>(Future<T> Function() call) async {
  try {
    return await call();
  } catch (error) {
    throw AndroidCodec.exception(error);
  }
}

final class PigeonAndroidFactoryTransport implements AndroidFactoryTransport {
  PigeonAndroidFactoryTransport() : _api = AndroidPlayerFactoryHostApi();
  final AndroidPlayerFactoryHostApi _api;
  @override
  Future<AndroidCreateReply> create(AndroidCreateRequest request) =>
      _invoke(() => _api.create(request));
}

final class PigeonAndroidPlayerTransport implements AndroidPlayerTransport {
  PigeonAndroidPlayerTransport(String suffix)
    : _api = AndroidPlayerHostApi(messageChannelSuffix: suffix);
  final AndroidPlayerHostApi _api;
  @override
  Future<void> attach() => _invoke(() => _api.attach());
  @override
  Future<AndroidAssessmentReply> assess(AndroidAssessRequest request) =>
      _invoke(() => _api.assess(request));
  @override
  Future<AndroidLoadReply> load(AndroidLoadRequest request) =>
      _invoke(() => _api.load(request));
  @override
  Future<void> play(AndroidSessionCommand command) =>
      _invoke(() => _api.play(command));
  @override
  Future<void> pause(AndroidSessionCommand command) =>
      _invoke(() => _api.pause(command));
  @override
  Future<void> seekTo(AndroidSeekCommand command) =>
      _invoke(() => _api.seekTo(command));
  @override
  Future<void> seekToLiveEdge(AndroidSessionCommand command) =>
      _invoke(() => _api.seekToLiveEdge(command));
  @override
  Future<void> setPlaybackSpeed(AndroidSpeedCommand command) =>
      _invoke(() => _api.setPlaybackSpeed(command));
  @override
  Future<void> selectAudioTrack(AndroidTrackCommand command) =>
      _invoke(() => _api.selectAudioTrack(command));
  @override
  Future<void> setVideoConstraints(AndroidVideoConstraintsCommand command) =>
      _invoke(() => _api.setVideoConstraints(command));
  @override
  Future<void> setVolume(double volume) =>
      _invoke(() => _api.setVolume(volume));
  @override
  Future<void> stop() => _invoke(() => _api.stop());
  @override
  Future<void> dispose() => _invoke(() => _api.dispose());
}
