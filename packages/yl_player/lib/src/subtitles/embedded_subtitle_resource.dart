import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'matroska_subtitles.dart';
import 'subtitle_resource.dart';
import 'embedded_subtitle_resource_stub.dart'
    if (dart.library.io) 'embedded_subtitle_resource_io.dart'
    as transport;

Future<List<EmbeddedSubtitleData>> readEmbeddedSubtitles(
  YlMediaSource source,
  SubtitleCancellation token,
) => transport.readEmbedded(source, token);
