import 'dart:io';
import 'subtitle_resource_io.dart' show SubtitleRangeReader;
import 'subtitle_document.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'matroska_subtitles.dart';
import 'mp4_subtitles.dart';
import 'subtitle_resource.dart';

Future<List<EmbeddedSubtitleData>> readEmbedded(
  YlMediaSource source,
  SubtitleCancellation token,
) async {
  if (source is YlNetworkSource) return _networkEmbedded(source, token);
  if (source is! YlFileSource ||
      ![
        YlMediaFormat.automatic,
        YlMediaFormat.matroska,
        YlMediaFormat.webm,
        YlMediaFormat.mp4,
      ].contains(source.format)) {
    throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
  }
  RandomAccessFile? file;
  final clock = Stopwatch()..start();
  try {
    token.check();
    // Refuse pipes/devices, whose open/read may never finish or support seeking.
    if (await FileSystemEntity.type(source.path) != FileSystemEntityType.file) {
      throw subtitleFailure(YlFailureCodes.sourceInvalid);
    }
    token.check();
    file = await File(source.path).open();
    final handle = file;
    final length = await handle.length();
    return await _parse(source.format, length, (offset, count) async {
      token.check();
      if (clock.elapsed > const Duration(seconds: 30)) {
        throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
      }
      await handle.setPosition(offset);
      return handle.read(count);
    }, token);
  } on FileSystemException {
    token.check();
    throw subtitleFailure(YlFailureCodes.sourceInvalid);
  } finally {
    if (file != null) {
      try {
        await file.close();
      } on FileSystemException {
        /* Preserve sanitized primary error. */
      }
    }
    clock.stop();
  }
}

Future<List<EmbeddedSubtitleData>> _networkEmbedded(
  YlNetworkSource source,
  SubtitleCancellation token,
) async {
  if (!['http', 'https'].contains(source.uri.scheme) ||
      source.drm != null ||
      source.intent == YlStreamIntent.live ||
      ![
        YlMediaFormat.automatic,
        YlMediaFormat.matroska,
        YlMediaFormat.webm,
        YlMediaFormat.mp4,
      ].contains(source.format)) {
    throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
  }
  final owned = SubtitleCancellation();
  final remove = token.listen(owned.cancel);
  SubtitleRangeReader? reader;
  Future<List<EmbeddedSubtitleData>> scan() async {
    reader = await SubtitleRangeReader.open(source, owned);
    owned.check();
    return _parse(source.format, reader!.length, reader!.read, owned);
  }

  try {
    final operation = scan();
    return await (source.networkPolicy.kind == YlNetworkPolicyKind.managed
        ? operation
        : operation.timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              owned.cancel();
              throw subtitleFailure(YlFailureCodes.networkFailed);
            },
          ));
  } catch (error) {
    token.check();
    if (error is YlPlayerException || error is SubtitleParseException) rethrow;
    throw subtitleFailure(YlFailureCodes.networkFailed);
  } finally {
    remove();
    owned.cancel();
    reader?.clear();
  }
}

Future<List<EmbeddedSubtitleData>> _parse(
  YlMediaFormat format,
  int length,
  Future<List<int>> Function(int, int) read,
  SubtitleCancellation token,
) async {
  token.check();
  final expectedDocType = switch (format) {
    YlMediaFormat.matroska => 'matroska',
    YlMediaFormat.webm => 'webm',
    _ => null,
  };
  if (format == YlMediaFormat.automatic) {
    if (length < 8) {
      throw const SubtitleParseException(SubtitleParseReason.malformed);
    }
    final signature = await read(0, 8);
    token.check();
    if (signature.length != 8) {
      throw const SubtitleParseException(SubtitleParseReason.malformed);
    }
    if (signature[0] == 0x1a &&
        signature[1] == 0x45 &&
        signature[2] == 0xdf &&
        signature[3] == 0xa3) {
      format = YlMediaFormat.matroska;
    } else if (String.fromCharCodes(signature.sublist(4)) == 'ftyp') {
      format = YlMediaFormat.mp4;
    } else {
      throw const SubtitleParseException(SubtitleParseReason.unsupported);
    }
  }
  return format == YlMediaFormat.mp4
      ? Mp4Subtitles(length, read, token).parse()
      : MatroskaSubtitles(
          length,
          read,
          token,
          expectedDocType: expectedDocType,
        ).parse();
}
