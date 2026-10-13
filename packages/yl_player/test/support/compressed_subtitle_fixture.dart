import 'dart:convert';
import 'dart:io';
import 'matroska_fixture.dart';
import 'embedded_vobsub_fixture.dart' show vobBlock;

List<int> compressionEncoding({
  int? algo = 0,
  int? scope,
  int? type,
  int? order,
  List<int>? settings,
  List<int> extra = const [],
}) => element(
  0x6d80,
  element(0x6240, [
    if (scope != null) ...uint(0x5032, scope),
    if (type != null) ...uint(0x5033, type),
    if (order != null) ...uint(0x5031, order),
    ...element(0x5034, [
      if (algo != null) ...uint(0x4254, algo),
      if (settings != null) ...element(0x4255, settings),
    ]),
    ...extra,
  ]),
);
List<int> compressedMkv({
  int algo = 0,
  int padding = 0,
  String text = 'compressed subtitle',
}) {
  final bytes = utf8.encode(text), header = bytes.take(3).toList();
  return mkv(
    tracks: track(
      extra: compressionEncoding(
        algo: algo,
        settings: algo == 3 ? header : null,
      ),
    ),
    extra: element(0xec, List.filled(padding, 0)),
    clusters: cluster(
      vobBlock(
        algo == 0 ? zlib.encode(bytes) : bytes.skip(3).toList(),
        time: 1000,
        duration: 1000,
      ),
      time: 0,
    ),
  );
}
