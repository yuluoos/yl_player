import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'subtitle_document.dart';
import 'subtitle_resource.dart';

/// Loads only the selected track around the current media position.
abstract interface class SubtitleWindowLoader {
  List<YlSubtitleTrack> get tracks;
  String windowKey(String id, Duration position);
  Future<SubtitleDocument> load(
    String id,
    Duration position,
    SubtitleCancellation token, {
    required int maxInputBytes,
    required int maxCues,
  });
  void clear();
}
