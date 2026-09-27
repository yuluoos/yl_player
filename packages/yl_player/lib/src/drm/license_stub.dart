import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'license_client.dart';

Future<YlDrmBytes> sendLicense(
  YlDrmLicenseEndpoint endpoint,
  YlDrmBytes challenge,
  YlDrmCancellationToken cancellation,
) async {
  throw ylDrmException(YlFailureCodes.drmUnsupported);
}
