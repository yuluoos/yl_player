import 'package:flutter/painting.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'subtitle_document.dart';
import 'subtitle_resource.dart';

final class TextSubtitleCue {
  const TextSubtitleCue(this.cue, this.text);
  final SubtitleCue cue;
  final TextSpan text;
}

final class _Document {
  _Document(this.document, this.text);
  final SubtitleDocument document;
  final List<TextSpan> text;
}

/// Internal single-owner catalog. Publication happens only after complete I/O,
/// parsing and markup validation, with a separate pending replacement budget.
final class TextSubtitleRuntime {
  YlSubtitleState state = YlSubtitleState();
  Map<String, _Document> _documents = {};
  SubtitleCancellation? _pending;
  void cancel() {
    _pending?.cancel();
    _pending = null;
  }

  void reset() {
    cancel();
    state = YlSubtitleState();
    _documents = {};
  }

  Future<void> replace(List<YlExternalSubtitle> sources) async {
    cancel();
    // Reject unsupported requests before reading any member of the catalog.
    for (final source in sources) {
      if (source.format != YlSubtitleFormat.srt &&
          source.format != YlSubtitleFormat.webvtt) {
        throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
      }
      if (source.source case YlNetworkSource(:final networkPolicy)) {
        if (networkPolicy.kind != YlNetworkPolicyKind.platformDefault) {
          throw subtitleFailure(YlFailureCodes.policyUnsupported);
        }
      }
    }
    final token = SubtitleCancellation();
    _pending = token;
    final documents = <String, _Document>{};
    var bytesLeft = 4 * 1024 * 1024;
    var cuesLeft = 10000;
    var runsLeft = 20000;
    try {
      for (final source in sources) {
        final bytes = await readSubtitleResource(
          source.source,
          token,
          bytesLeft,
        );
        token.check();
        final doc = SubtitleDocument.parse(
          bytes,
          format: source.format == YlSubtitleFormat.srt
              ? SubtitleFormat.srt
              : SubtitleFormat.webvtt,
        );
        bytesLeft -= bytes.length;
        cuesLeft -= doc.cues.length;
        if (cuesLeft < 0) {
          throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
        }
        final text = <TextSpan>[];
        for (final cue in doc.cues) {
          final span = parseSubtitleText(cue.payload);
          runsLeft -= span.children!.length;
          if (runsLeft < 0) {
            throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
          }
          text.add(span);
        }
        documents[source.id] = _Document(doc, text);
      }
      token.check();
      _documents = documents;
      state = state.copyWith(
        tracks: [
          for (final source in sources)
            YlSubtitleTrack(
              id: source.id,
              format: source.format,
              isExternal: true,
              label: source.label,
              language: source.language,
              role: source.role,
              contentId: source.contentId,
            ),
        ],
        selectedTrackId: documents.containsKey(state.selectedTrackId)
            ? state.selectedTrackId
            : null,
      );
    } on SubtitleParseException catch (error) {
      throw subtitleFailure(switch (error.reason) {
        SubtitleParseReason.malformed => YlFailureCodes.subtitleMalformed,
        SubtitleParseReason.unsupported => YlFailureCodes.subtitleUnsupported,
        SubtitleParseReason.limitExceeded => YlFailureCodes.subtitleTooLarge,
      });
    } finally {
      if (identical(_pending, token)) _pending = null;
      token.cancel();
    }
  }

  void select(String? id) {
    if (id != null && !_documents.containsKey(id)) {
      throw subtitleFailure(YlFailureCodes.sourceInvalid);
    }
    state = state.copyWith(selectedTrackId: id);
  }

  void offset(Duration value) => state = state.copyWith(offset: value);
  List<TextSubtitleCue> cuesAt(Duration position) {
    final doc = _documents[state.selectedTrackId];
    if (doc == null) return const [];
    return [
      for (final cue in doc.document.cuesAt(position, offset: state.offset))
        TextSubtitleCue(cue, doc.text[cue.ordinal]),
    ];
  }
}

/// A deliberately closed markup subset. Never treats payload as HTML or loads
/// fonts/images. Rejects unknown tags instead of displaying raw control markup.
TextSpan parseSubtitleText(String payload) {
  if (payload.contains(r'{\')) {
    throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
  }
  final spans = <TextSpan>[];
  final stack = <String>[];
  var cursor = 0;
  void malformed() => throw subtitleFailure(YlFailureCodes.subtitleMalformed);
  while (cursor < payload.length) {
    if (payload[cursor] == '<') {
      final end = payload.indexOf('>', cursor);
      if (end < 0) malformed();
      final tag = payload.substring(cursor + 1, end);
      final closing = tag.startsWith('/');
      final name = closing ? tag.substring(1) : tag;
      if (!['b', 'i', 'u'].contains(name)) {
        throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
      }
      if (closing) {
        if (stack.isEmpty || stack.removeLast() != name) malformed();
      } else {
        if (stack.length >= 16) {
          throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
        }
        stack.add(name);
      }
      cursor = end + 1;
      continue;
    }
    final end = payload.indexOf('<', cursor);
    final raw = payload.substring(cursor, end < 0 ? payload.length : end);
    final text = raw.replaceAllMapped(RegExp(r'&([^;\s]{1,16});'), (match) {
      final entity = match[1]!;
      const named = {
        'amp': '&',
        'lt': '<',
        'gt': '>',
        'nbsp': '\u00a0',
        'lrm': '\u200e',
        'rlm': '\u200f',
        'quot': '"',
        'apos': "'",
      };
      if (named.containsKey(entity)) return named[entity]!;
      if (!entity.startsWith('#')) {
        throw subtitleFailure(YlFailureCodes.subtitleUnsupported);
      }
      final hex = entity.startsWith('#x');
      final value = int.tryParse(
        entity.substring(hex ? 2 : 1),
        radix: hex ? 16 : 10,
      );
      if (value == null ||
          value <= 0 ||
          value > 0x10ffff ||
          (value >= 0xd800 && value <= 0xdfff)) {
        malformed();
      }
      return String.fromCharCode(value!);
    });
    spans.add(
      TextSpan(
        text: text,
        style: TextStyle(
          fontWeight: stack.contains('b') ? FontWeight.bold : FontWeight.normal,
          fontStyle: stack.contains('i') ? FontStyle.italic : FontStyle.normal,
          decoration: stack.contains('u')
              ? TextDecoration.underline
              : TextDecoration.none,
        ),
      ),
    );
    if (spans.length > 512) {
      throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
    }
    cursor = end < 0 ? payload.length : end;
  }
  if (stack.isNotEmpty) malformed();
  return TextSpan(children: spans);
}
