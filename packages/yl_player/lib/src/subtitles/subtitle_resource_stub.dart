import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'subtitle_resource.dart';
import 'dash_subtitle_resource.dart';

Future<List<int>> read(
  YlMediaSource source,
  SubtitleCancellation token,
  int maxBytes,
) async {
  throw subtitleFailure(YlFailureCodes.policyUnsupported);
}

DashSubtitleReader createDashReader(YlMediaSource source) =>
    throw subtitleFailure(YlFailureCodes.policyUnsupported);
