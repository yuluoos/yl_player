import '../model/value_helpers.dart';
import '../drm/drm_config.dart';
import '../options/policies.dart';
import 'http_request.dart';

enum YlStreamIntent { automatic, onDemand, live }

enum YlMediaFormat {
  automatic,
  hls,
  mp4,
  mov,
  matroska,
  webm,
  mpegTs,
  mpegPs,
  flv,
  avi,
  dash,
}

/// Closed source family. Source identities and request metadata are sensitive.
sealed class YlMediaSource {
  const YlMediaSource({required this.intent, required this.format});

  final YlStreamIntent intent;
  final YlMediaFormat format;
}

final class YlFileSource extends YlMediaSource {
  const YlFileSource(this.path, {super.format = YlMediaFormat.automatic})
    : super(intent: YlStreamIntent.onDemand);

  final String path;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        path == other.path && intent == other.intent && format == other.format,
  );

  @override
  int get hashCode => Object.hash(YlFileSource, path, intent, format);

  @override
  String toString() => 'YlFileSource(<redacted>, format: ${format.name})';
}

/// HTTP(S) media or a syntactically valid RTMP(S) endpoint. Admission does not
/// imply native playback support: Apple supports RTMP/RTMPS; Android supports
/// plain RTMP. Native assessment supports automatic/FLV with automatic/live intent and rejects
/// HTTP request metadata, managed HTTP policy, bounded buffering, on-demand
/// intent, nonzero initial positions, and all runtime time seeks (including
/// zero) instead of ignoring them. `seekToLiveEdge` supports a fresh live open.
///
/// RTMP uses port 1935 when absent. The first raw path segment is the app;
/// the remaining raw path plus query is the playpath. Validation limits the
/// supplied URI serialization to 8192 UTF-8 bytes and requires both components.
/// It rejects userinfo, fragments, malformed escapes, decoded controls and
/// invalid explicit ports. The supplied [uri] is retained unchanged; any
/// normalization already performed by Uri.parse cannot be recovered (including
/// percent spelling, empty userinfo, and empty or zero ports).
final class YlNetworkSource extends YlMediaSource {
  YlNetworkSource(
    this.uri, {
    super.intent = YlStreamIntent.automatic,
    super.format = YlMediaFormat.automatic,
    YlHttpRequest? request,
    this.drm,
    this.networkPolicy = const YlNetworkPolicy.platformDefault(),
  }) : request = request ?? YlHttpRequest();

  final Uri uri;
  final YlDrmConfig? drm;
  final YlHttpRequest request;

  /// Controls transport enforcement for this source. It does not relax codec
  /// admission or guarantee that the media supports seeking or output capture.
  final YlNetworkPolicy networkPolicy;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        uri == other.uri &&
        intent == other.intent &&
        format == other.format &&
        drm == other.drm &&
        request == other.request &&
        networkPolicy == other.networkPolicy,
  );

  @override
  int get hashCode => Object.hash(
    YlNetworkSource,
    uri,
    intent,
    format,
    request,
    networkPolicy,
    drm,
  );

  @override
  String toString() =>
      'YlNetworkSource(<redacted>, intent: ${intent.name}, '
      'format: ${format.name}, networkPolicy: ${networkPolicy.kind.name})';
}

final class YlAndroidContentSource extends YlMediaSource {
  const YlAndroidContentSource(
    this.uri, {
    super.intent = YlStreamIntent.automatic,
    super.format = YlMediaFormat.automatic,
  });

  final Uri uri;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        uri == other.uri && intent == other.intent && format == other.format,
  );

  @override
  int get hashCode => Object.hash(YlAndroidContentSource, uri, intent, format);

  @override
  String toString() =>
      'YlAndroidContentSource(<redacted>, intent: ${intent.name}, '
      'format: ${format.name})';
}
