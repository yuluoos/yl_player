import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'matroska_subtitles.dart';
import 'subtitle_resource.dart';
import 'subtitle_window_loader.dart';

Future<List<EmbeddedSubtitleData>> readEmbedded(
  YlMediaSource source,
  SubtitleCancellation token, {
  void Function(SubtitleWindowLoader)? onIndexed,
}) async {
  throw subtitleFailure(YlFailureCodes.policyUnsupported);
}
