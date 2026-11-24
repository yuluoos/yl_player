part of 'mp4_subtitles.dart';

/// A progressive movie's immutable sample tables can serve any playback position.
final class _Mp4SubtitleWindow implements SubtitleWindowLoader {
  _Mp4SubtitleWindow(
    this.length,
    this.movieScale,
    this.choices,
    this.mdats,
    this.metadata,
    this.start,
    this.open,
  );

  final int length, movieScale, start;
  final Map<String, ({YlSubtitleTrack track, _Box box})> choices;
  final List<_Box> mdats;
  final Uint8List? metadata;
  final Future<List<int>> Function(int, int) Function(SubtitleCancellation)
  open;
  static const _windowUs = 8 * Duration.microsecondsPerSecond;

  @override
  late final tracks = List<YlSubtitleTrack>.unmodifiable(
    choices.values.map((e) => e.track),
  );
  @override
  String windowKey(String id, Duration position) =>
      '$id:${position.inMicroseconds ~/ _windowUs}';
  @override
  void clear() {} // Only immutable catalog data is shared between windows.

  @override
  Future<SubtitleDocument> load(
    String id,
    Duration position,
    SubtitleCancellation token, {
    required int maxInputBytes,
    required int maxCues,
  }) async {
    final choice = choices[id];
    if (choice == null) _bad();
    if (maxCues < 1 || maxInputBytes < 1) _limit();
    final from = (position.inMicroseconds ~/ _windowUs) * _windowUs;
    final parser = Mp4Subtitles(length, open(token), token)
      .._mdats.addAll(mdats)
      .._movieMetadata = metadata
      .._metadataStart = start
      .._window = (start: from, end: from + 2 * _windowUs);
    final data = await parser._track(choice.box, movieScale);
    if (data == null || data.track.id != id) _bad();
    if (parser._payloadBytes > maxInputBytes || data.packets.length > maxCues) {
      _limit();
    }
    return SubtitleDocument.fromEmbeddedPackets(
      data.packets,
      format: switch (data.track.format) {
        YlSubtitleFormat.webvtt => SubtitleFormat.webvtt,
        YlSubtitleFormat.ttml => SubtitleFormat.ttml,
        _ => SubtitleFormat.srt,
      },
      sourceBytes: data.sourceBytes,
      limits: SubtitleLimits(maxInputBytes: maxInputBytes, maxCues: maxCues),
    );
  }
}
