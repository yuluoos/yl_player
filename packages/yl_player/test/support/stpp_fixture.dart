import 'dart:convert';
import 'mp4_fixture.dart';
export 'mp4_fixture.dart';

const ttmlNamespace = 'http://www.w3.org/ns/ttml';
List<int> stppEntry({
  String namespace = ttmlNamespace,
  String schema = '',
  String auxiliary = '',
  List<int> extra = const [],
}) => box('stpp', [
  ...List.filled(6, 0),
  ...num(1, 2),
  ...utf8.encode(namespace),
  0,
  ...utf8.encode(schema),
  0,
  ...utf8.encode(auxiliary),
  0,
  ...extra,
]);
String ttmlDocument(String body, {String head = '', String attributes = ''}) =>
    '<tt xmlns="$ttmlNamespace" xmlns:tts="$ttmlNamespace#styling" xmlns:ttp="$ttmlNamespace#parameter" $attributes>$head<body><div>$body</div></body></tt>';
List<int> stppSample(String body, {String head = '', String attributes = ''}) =>
    utf8.encode(ttmlDocument(body, head: head, attributes: attributes));
Mp4Track stppTrack({
  int id = 1,
  List<List<int>>? samples,
  List<int>? durations,
  List<int>? entry,
  List<int>? edits,
  List<int>? ctts,
  int scale = 1000,
}) => Mp4Track(
  id: id,
  handler: 'subt',
  entry: entry ?? stppEntry(),
  samples: samples ?? [stppSample('<p begin="0s" end="1s">hello</p>')],
  durations: durations,
  edits: edits,
  ctts: ctts,
  scale: scale,
);
