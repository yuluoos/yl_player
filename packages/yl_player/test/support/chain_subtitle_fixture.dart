import 'dart:convert';
import 'dart:io';
import 'matroska_fixture.dart';
import 'embedded_vobsub_fixture.dart' show vobBlock;
export 'matroska_fixture.dart';
export 'embedded_vobsub_fixture.dart' show vobBlock;

class EncodingStage {
  const EncodingStage(
    this.order, {
    this.scope = 3,
    this.algo = 0,
    this.header = const [],
  });
  final int order, scope, algo;
  final List<int> header;
  List<int> get bytes => element(0x6240, [
    ...uint(0x5031, order),
    ...uint(0x5032, scope),
    ...element(0x5034, [
      ...uint(0x4254, algo),
      if (algo == 3) ...element(0x4255, header),
    ]),
  ]);
}

const doubleZlib = [EncodingStage(0), EncodingStage(1)];
List<int> encodedChain(
  List<int> input,
  List<EncodingStage> stages,
  int scope, {
  bool stored = false,
}) {
  var out = input;
  for (final s in [...stages]..sort((a, b) => a.order.compareTo(b.order))) {
    if (s.scope & scope == 0) continue;
    if (s.algo == 0) {
      out = stored ? ZLibEncoder(level: 0).convert(out) : zlib.encode(out);
    } else {
      if (out.length < s.header.length ||
          List.generate(
            s.header.length,
            (i) => out[i] == s.header[i],
          ).contains(false)) {
        throw StateError('Fixture header mismatch');
      }
      out = out.sublist(s.header.length);
    }
  }
  return out;
}

List<int> chainTrack({
  List<EncodingStage> stages = doubleZlib,
  String codec = 'S_TEXT/WEBVTT',
  List<int>? header,
  int number = 1,
  int uid = 101,
  bool forced = false,
  bool stored = false,
}) => track(
  codec: codec,
  number: number,
  uid: uid,
  forced: forced,
  extra: [
    ...element(
      0x63a2,
      encodedChain(header ?? utf8.encode('WEBVTT'), stages, 2, stored: stored),
    ),
    ...element(0x6d80, [for (final s in stages) ...s.bytes]),
  ],
);
List<int> chainMkv({
  List<EncodingStage> stages = doubleZlib,
  String text = 'hello',
  int padding = 0,
}) => mkv(
  tracks: chainTrack(stages: stages),
  extra: element(0xec, List.filled(padding, 0)),
  clusters: cluster(
    vobBlock(
      encodedChain(utf8.encode(text), stages, 1),
      time: 1000,
      duration: 1000,
    ),
    time: 0,
  ),
);
