import 'drm_config.dart';

/// Configured by the controller. Cancellation settles on completion as well, so
/// a transport must remove listeners when its request finishes.
typedef YlDrmLicenseExchange =
    Future<YlDrmBytes> Function(
      YlDrmLicenseEndpoint endpoint,
      YlDrmBytes challenge,
      Future<void> cancelled,
    );

abstract interface class YlPlatformDrmLicenseTransport {
  void setDrmLicenseExchange(YlDrmLicenseExchange exchange);
}
