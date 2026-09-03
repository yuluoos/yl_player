import 'dart:collection';

/// Identifies how a media URI should be opened by a platform backend.
enum YlMediaSourceKind { file, network, content }

/// Helps route media whose URI or MIME type is missing or misleading.
enum YlFormatHint {
  automatic,
  hls,
  httpFlv,
  mp4,
  mov,
  matroska,
  webm,
  mpegTs,
  mpegPs,
  flv,
  avi,
}

/// A resolved media source accepted by `yl_player`.
final class YlMediaSource {
  YlMediaSource._({
    required this.uri,
    required this.kind,
    required this.isLive,
    required this.formatHint,
    required Map<String, String> headers,
  }) : headers = UnmodifiableMapView<String, String>(
         Map<String, String>.of(headers),
       );

  factory YlMediaSource.content(
    Uri uri, {
    bool isLive = false,
    YlFormatHint formatHint = YlFormatHint.automatic,
  }) {
    if (uri.scheme != 'content') {
      throw ArgumentError.value(uri, 'uri', 'Expected a content URI.');
    }
    return YlMediaSource._(
      uri: uri,
      kind: YlMediaSourceKind.content,
      isLive: isLive,
      formatHint: formatHint,
      headers: const <String, String>{},
    );
  }

  factory YlMediaSource.file(
    String path, {
    YlFormatHint formatHint = YlFormatHint.automatic,
  }) => YlMediaSource._(
    uri: Uri.file(path),
    kind: YlMediaSourceKind.file,
    isLive: false,
    formatHint: formatHint,
    headers: const <String, String>{},
  );

  factory YlMediaSource.network(
    Uri uri, {
    bool isLive = false,
    YlFormatHint formatHint = YlFormatHint.automatic,
    Map<String, String> headers = const <String, String>{},
  }) {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw ArgumentError.value(uri, 'uri', 'Expected an HTTP or HTTPS URI.');
    }
    return YlMediaSource._(
      uri: uri,
      kind: YlMediaSourceKind.network,
      isLive: isLive,
      formatHint: formatHint,
      headers: headers,
    );
  }

  final Uri uri;
  final YlMediaSourceKind kind;
  final bool isLive;
  final YlFormatHint formatHint;
  final Map<String, String> headers;
}
