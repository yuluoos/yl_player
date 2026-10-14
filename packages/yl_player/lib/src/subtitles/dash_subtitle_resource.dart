import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'subtitle_resource.dart';
import 'subtitle_resource_stub.dart'
    if (dart.library.io) 'subtitle_resource_io.dart'
    as transport;

/// A resolved resource and its monotonic credential ancestry. Returning to the
/// original origin never grants credentials that an earlier edge stripped.
final class DashSubtitleLocation {
  const DashSubtitleLocation(this.uri, {this.credentialsStripped = false});
  final Uri uri;
  final bool credentialsStripped;
  DashSubtitleLocation resolve(String reference) {
    final target = uri.resolve(reference);
    if (reference.length > 8192 ||
        target.toString().length > 8192 ||
        target.userInfo.isNotEmpty ||
        target.hasFragment ||
        (uri.scheme == 'file'
            ? target.scheme != 'file' || target.host.isNotEmpty
            : !['http', 'https'].contains(target.scheme)) ||
        (uri.scheme == 'https' && target.scheme != 'https')) {
      throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
    }
    return DashSubtitleLocation(
      target,
      credentialsStripped:
          credentialsStripped ||
          uri.scheme != target.scheme ||
          uri.host != target.host ||
          uri.port != target.port,
    );
  }
}

final class DashSubtitleRange {
  const DashSubtitleRange(this.start, this.length);
  final int start, length;
}

final class DashSubtitleResource {
  DashSubtitleResource(List<DashSubtitleLocation> locations, {this.range})
    : locations = List.unmodifiable(locations);
  final List<DashSubtitleLocation> locations;
  final DashSubtitleRange? range;
  String get key =>
      '${range?.start}:${range?.length}:${locations.map((v) => '${v.uri.toString().length}:${v.uri}').join()}';
}

final class DashSubtitleReply {
  DashSubtitleReply(this.bytes, this.location, {this.sourceOffset = 0});
  final List<int> bytes;
  final DashSubtitleLocation location;
  final int sourceOffset;
}

/// One discovery/session owns request histories; repeated seeks and candidate
/// URLs cannot reset retry limits. Runtime generation tokens cancel all I/O.
abstract interface class DashSubtitleReader {
  Future<DashSubtitleReply> root(SubtitleCancellation token);
  Future<DashSubtitleReply> read(
    DashSubtitleResource resource,
    SubtitleCancellation token,
    int maxBytes,
  );
}

DashSubtitleReader createDashSubtitleReader(YlMediaSource source) =>
    transport.createDashReader(source);
