import 'package:yl_player/yl_player.dart';

// Test-owned handles let shared fixture helpers operate on the session returned
// by Load. A failed candidate never replaces the retained successful handle.
final _sessions = Expando<YlPlaybackSession>();
Future<YlPlaybackSession> loadSession(
  YlPlayerController player,
  YlMediaSource source, {
  YlLoadOptions options = const YlLoadOptions(),
}) async {
  final session = await player.load(source, options: options);
  _sessions[player] = session;
  return session;
}

YlPlaybackSession sessionFor(YlPlayerController player) => _sessions[player]!;
