import 'dart:convert';
import 'dart:io';
import 'matroska_fixture.dart';
import 'compressed_subtitle_fixture.dart';
import 'embedded_vobsub_fixture.dart' show vobBlock;

List<int> privateTrack({
  String codec = 'S_TEXT/WEBVTT',
  List<int>? header,
  int scope = 2,
  int algo = 0,
  List<int> settings = const [],
  int number = 1,
  int uid = 101,
  List<int> extra = const [],
  bool forced = false,
}) {
  final bytes = header ?? utf8.encode('WEBVTT');
  return track(
    codec: codec,
    number: number,
    uid: uid,
    forced: forced,
    extra: [
      ...element(
        0x63a2,
        scope & 2 != 0
            ? (algo == 0
                  ? zlib.encode(bytes)
                  : bytes.skip(settings.length).toList())
            : bytes,
      ),
      ...compressionEncoding(
        algo: algo,
        scope: scope,
        settings: algo == 3 ? settings : null,
      ),
      ...extra,
    ],
  );
}

List<int> privateMkv({
  int scope = 2,
  int algo = 0,
  int padding = 0,
  String text = 'hello',
  String header = 'WEBVTT',
}) => mkv(
  tracks: privateTrack(scope: scope, algo: algo, header: utf8.encode(header)),
  extra: element(0xec, List.filled(padding, 0)),
  clusters: cluster(
    vobBlock(
      scope & 1 != 0 && algo == 0
          ? zlib.encode(utf8.encode(text))
          : utf8.encode(text),
      time: 1000,
      duration: 1000,
    ),
    time: 0,
  ),
);
