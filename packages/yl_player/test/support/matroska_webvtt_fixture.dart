import 'matroska_fixture.dart';

List<int> additions(String text, {int? id = 1}) => element(
  0x75a1,
  element(0xa6, [if (id != null) ...uint(0xee, id), ...str(0xa5, text)]),
);
List<int> fixture({
  String codec = 'S_TEXT/WEBVTT',
  String? header = 'WEBVTT\n\nNOTE owned header',
  String text = '<b>hello</b>',
  List<int> extra = const [],
  List<int> trackExtra = const [],
  int? duration = 1000,
}) => mkv(
  tracks: track(codec: codec, private: header, extra: trackExtra),
  clusters: cluster(block(text: text, extra: extra, duration: duration)),
);
