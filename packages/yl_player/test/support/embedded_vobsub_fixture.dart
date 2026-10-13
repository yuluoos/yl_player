import 'matroska_fixture.dart';
import 'vobsub_fixture.dart';

String vobPrivate() => vobIdxText().split('\nid:').first;
List<int> vobBlock(
  List<int> bytes, {
  int number = 1,
  int time = 1000,
  int? duration,
  bool simple = false,
  List<int> extra = const [],
  int flags = 0,
}) {
  final body = [...vint(number), ...be(time & 65535, 2), flags, ...bytes];
  return simple
      ? element(0xa3, body)
      : element(0xa0, [
          ...element(0xa1, body),
          if (duration != null) ...uint(0x9b, duration),
          ...extra,
        ]);
}

List<int> embeddedVobSub({List<int>? spu, int padding = 0}) => mkv(
  tracks: track(codec: 'S_VOBSUB', private: vobPrivate()),
  extra: element(0xec, List.filled(padding, 0)),
  clusters: cluster(vobBlock(spu ?? vobAnimated(), duration: 1500), time: 0),
);
