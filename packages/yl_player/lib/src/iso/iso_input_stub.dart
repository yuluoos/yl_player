import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'iso_input.dart';

IsoInput create(YlMediaSource source) => throw isoError(
  YlFailureCodes.policyUnsupported,
  'Disc images require a native player.',
);
