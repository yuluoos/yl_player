import '../model/value_helpers.dart';
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

final class YlNetworkSource extends YlMediaSource {
  YlNetworkSource(
    this.uri, {
    super.intent = YlStreamIntent.automatic,
    super.format = YlMediaFormat.automatic,
    YlHttpRequest? request,
    this.networkPolicy = const YlNetworkPolicy.platformDefault(),
  }) : request = request ?? YlHttpRequest();

  final Uri uri;
  final YlHttpRequest request;
  final YlNetworkPolicy networkPolicy;

  @override
  bool operator ==(Object other) => ylValueEquals(
    this,
    other,
    (other) =>
        uri == other.uri &&
        intent == other.intent &&
        format == other.format &&
        request == other.request &&
        networkPolicy == other.networkPolicy,
  );

  @override
  int get hashCode =>
      Object.hash(YlNetworkSource, uri, intent, format, request, networkPolicy);

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
