import 'dart:convert';
import 'mp4_fixture.dart';
export 'mp4_fixture.dart';

List<int> wvttEntry({String config = 'WEBVTT\n', List<int> extra = const []}) =>
    box('wvtt', [
      ...List.filled(6, 0),
      ...num(1, 2),
      ...box('vttC', utf8.encode(config)),
      ...extra,
    ]);
List<int> vttCue(
  String text, {
  String? id,
  String? settings,
  String? time,
  List<int> extra = const [],
}) => box('vttc', [
  if (id != null) ...box('iden', utf8.encode(id)),
  if (settings != null) ...box('sttg', utf8.encode(settings)),
  if (time != null) ...box('ctim', utf8.encode(time)),
  ...box('payl', utf8.encode(text)),
  ...extra,
]);
Mp4Track wvttTrack({
  int id = 1,
  List<List<int>>? samples,
  List<int>? durations,
  List<int>? entry,
  List<int>? edits,
  int scale = 1000,
}) => Mp4Track(
  id: id,
  handler: 'text',
  entry: entry ?? wvttEntry(),
  samples: samples ?? [vttCue('hello')],
  durations: durations,
  edits: edits,
  scale: scale,
);
