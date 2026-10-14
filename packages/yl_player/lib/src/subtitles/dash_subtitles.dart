import 'dart:convert';
import 'package:xml/xml.dart' show XmlDefaultEntityMapping, XmlException;
import 'package:xml/xml_events.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'dash_subtitle_resource.dart';
import 'subtitle_resource.dart';
import 'subtitle_document.dart';
import 'mp4_subtitles.dart';

part 'dash_subtitle_time.dart';
part 'dash_subtitle_catalog.dart';
part 'dash_subtitle_window.dart';

Never _dashBad() => throw subtitleFailure(YlFailureCodes.subtitleMalformed);
Never _dashUnsupported() =>
    throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
Never _dashLimit() => throw subtitleFailure(YlFailureCodes.subtitleTooLarge);

/// Static MPD subtitle choices and exact half-open programme windows. Discovery
/// reads metadata only; segment bytes belong to the selected runtime window.
final class DashSubtitleCatalog {
  DashSubtitleCatalog._(this.periods, this.tracks, this.duration);
  final List<DashSubtitlePeriod> periods;
  final List<YlSubtitleTrack> tracks;
  final DashSubtitleTime duration;
  static DashSubtitleCatalog parse(List<int> bytes, DashSubtitleLocation root) {
    try {
      return _DashCatalogParser(root).parse(bytes);
    } on YlPlayerException {
      rethrow;
    } on FormatException {
      return _dashBad();
    } on XmlException {
      return _dashBad();
    } on ArgumentError {
      return _dashBad();
    }
  }

  DashSubtitlePeriod? periodAt(Duration position) {
    final at = DashSubtitleTime.of(position.inMicroseconds, 1000000);
    for (final period in periods) {
      if (at >= period.start && at < period.end) return period;
    }
    return null;
  }
}

final class DashSubtitlePeriod {
  DashSubtitlePeriod(this.start, this.end, List<DashSubtitleTrack> tracks)
    : tracks = List.unmodifiable(tracks);
  final DashSubtitleTime start, end;
  final List<DashSubtitleTrack> tracks;
}

final class DashSubtitleTrack {
  DashSubtitleTrack(
    this.metadata,
    this.offset,
    this.initialization,
    List<DashSubtitleSegment> segments, {
    required this.fragmented,
  }) : segments = List.unmodifiable(segments);
  final YlSubtitleTrack metadata;
  String get id => metadata.id;
  final DashSubtitleTime offset;
  final DashSubtitleResource? initialization;
  final List<DashSubtitleSegment> segments;
  final bool fragmented;
}

final class DashSubtitleSegment {
  DashSubtitleSegment(this.start, this.duration, this.resource);
  final DashSubtitleTime start, duration;
  final DashSubtitleResource resource;
}
