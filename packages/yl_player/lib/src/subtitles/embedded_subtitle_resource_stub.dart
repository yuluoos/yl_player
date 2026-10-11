import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'matroska_subtitles.dart';
import 'subtitle_resource.dart';

Future<List<EmbeddedSubtitleData>> readEmbedded(
  YlMediaSource source,
  SubtitleCancellation token,
) async {
  throw subtitleFailure(YlFailureCodes.policyUnsupported);
}
