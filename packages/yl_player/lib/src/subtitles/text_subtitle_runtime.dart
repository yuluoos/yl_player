import 'package:flutter/painting.dart';
import 'package:yl_player_platform_interface/yl_player_platform_interface.dart';
import 'subtitle_document.dart';
import 'subtitle_resource.dart';
import 'embedded_subtitle_resource.dart';

final class TextSubtitleCue {
  const TextSubtitleCue(this.cue, this.text, {this.elapsed = Duration.zero});
  final Duration elapsed;
  final SubtitleCue cue;
  final TextSpan text;
}

final class _Document {
  _Document(this.document, this.text);
  final SubtitleDocument document;
  final List<TextSpan> text;
  int get runs => text.fold<int>(0, (n, span) => n + span.children!.length);
}

/// Internal single-owner catalog. Publication happens only after complete I/O,
/// parsing and markup validation, with a separate pending replacement budget.
final class TextSubtitleRuntime {
  YlSubtitleState state = YlSubtitleState();
  Map<String, _Document> _documents = {};
  SubtitleCancellation? _pending;
  Future<void> _scanTail = Future.value();
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
    // Pair shape is also checked here for internal callers before I/O.
    for (final source in sources) {
      if ((source.format == YlSubtitleFormat.vobsub) !=
          (source.companionSource != null)) {
        throw subtitleFailure(YlFailureCodes.subtitleMalformed);
      }
    }
    final token = SubtitleCancellation();
    _pending = token;
    final retained = state.tracks.where((t) => !t.isExternal).toList();
    final documents = {for (final t in retained) t.id: _documents[t.id]!};
    if (sources.any((s) => documents.containsKey(s.id))) {
      _pending = null;
      token.cancel();
      throw subtitleFailure(YlFailureCodes.sourceInvalid);
    }
    var bytesLeft =
        4 * 1024 * 1024 -
        documents.values.fold<int>(0, (n, d) => n + d.document.inputBytes);
    var cuesLeft =
        10000 -
        documents.values.fold<int>(0, (n, d) => n + d.document.cues.length);
    var runsLeft = 20000 - documents.values.fold<int>(0, (n, d) => n + d.runs);
    var bitmapBytesLeft =
        64 * 1024 * 1024 -
        documents.values.fold<int>(0, (n, d) => n + d.document.pgsBitmapBytes);
    try {
      for (final source in sources) {
        final index = source.companionSource == null
            ? null
            : await readSubtitleResource(
                source.companionSource!,
                token,
                bytesLeft,
              );
        if (index != null) bytesLeft -= index.length;
        token.check();
        final bytes = await readSubtitleResource(
          source.source,
          token,
          bytesLeft,
        );
        token.check();
        final limits = SubtitleLimits(
          maxAssRuns: runsLeft,
          maxPgsBitmapBytes: bitmapBytesLeft,
        );
        final doc = index != null
            ? SubtitleDocument.parseVobSub(
                bytes,
                index,
                limits: limits,
                language: source.language,
              )
            : SubtitleDocument.parse(
                bytes,
                limits: limits,
                format: switch (source.format) {
                  YlSubtitleFormat.srt => SubtitleFormat.srt,
                  YlSubtitleFormat.webvtt => SubtitleFormat.webvtt,
                  YlSubtitleFormat.ass => SubtitleFormat.ass,
                  YlSubtitleFormat.ssa => SubtitleFormat.ssa,
                  YlSubtitleFormat.pgs => SubtitleFormat.pgs,
                  _ => SubtitleFormat.ttml,
                },
              );
        bitmapBytesLeft -= doc.pgsBitmapBytes;
        bytesLeft -= bytes.length;
        cuesLeft -= doc.cues.length;
        if (cuesLeft < 0) {
          throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
        }
        final rendered = _renderDocument(doc, runsLeft);
        runsLeft -= rendered.runs;
        documents[source.id] = rendered;
      }
      token.check();
      _documents = documents;
      state = state.copyWith(
        tracks: [
          ...retained,
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

  /// Serial file scans prevent rapid cancellation/retry from retaining many
  /// open media descriptors. The latest catalog operation wins publication.
  Future<void> discover(YlMediaSource source) {
    cancel();
    final token = SubtitleCancellation();
    _pending = token;
    final prior = _scanTail;
    final work = () async {
      try {
        await prior;
        token.check();
        final data = await readEmbeddedSubtitles(source, token);
        token.check();
        final retained = state.tracks.where((t) => t.isExternal).toList();
        final documents = {for (final t in retained) t.id: _documents[t.id]!};
        var bytesLeft =
            4 * 1024 * 1024 -
            documents.values.fold<int>(0, (n, d) => n + d.document.inputBytes);
        var cuesLeft =
            10000 -
            documents.values.fold<int>(0, (n, d) => n + d.document.cues.length);
        var runsLeft =
            20000 - documents.values.fold<int>(0, (n, d) => n + d.runs);
        for (final entry in data) {
          token.check();
          if (documents.containsKey(entry.track.id)) {
            throw subtitleFailure(YlFailureCodes.sourceInvalid);
          }
          // Zero remaining budget still allows an empty track; parse with the
          // hard ceiling then check aggregate before any publication.
          final doc = SubtitleDocument.fromEmbeddedPackets(
            entry.packets,
            format: switch (entry.track.format) {
              YlSubtitleFormat.ass => SubtitleFormat.ass,
              YlSubtitleFormat.ssa => SubtitleFormat.ssa,
              _ => SubtitleFormat.srt,
            },
            codecPrivate: entry.codecPrivate,
            limits: SubtitleLimits(maxAssRuns: runsLeft),
          );
          bytesLeft -= doc.inputBytes;
          cuesLeft -= doc.cues.length;
          if (bytesLeft < 0 || cuesLeft < 0) {
            throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
          }
          final rendered = _renderDocument(doc, runsLeft);
          runsLeft -= rendered.runs;
          documents[entry.track.id] = rendered;
        }
        token.check();
        _documents = documents;
        state = state.copyWith(
          tracks: [...data.map((d) => d.track), ...retained],
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
    }();
    _scanTail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
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
        TextSubtitleCue(
          cue,
          doc.text[cue.ordinal],
          elapsed: position - state.offset - cue.start,
        ),
    ];
  }
}

_Document _renderDocument(SubtitleDocument doc, int runsLeft) {
  final text = <TextSpan>[];
  for (final cue in doc.cues) {
    final span = cue.pgs != null
        ? const TextSpan(children: [])
        : cue.ass != null
        ? TextSpan(
            children: [
              for (final run in cue.ass!.runs)
                TextSpan(
                  text: run.text,
                  style: TextStyle(
                    fontWeight: run.style.bold
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
            ],
          )
        : cue.textRuns == null
        ? parseSubtitleText(cue.payload)
        : TextSpan(
            children: [
              for (final run in cue.textRuns!)
                TextSpan(
                  text: run.text,
                  style: TextStyle(
                    fontWeight: run.bold ? FontWeight.bold : FontWeight.normal,
                    fontStyle: run.italic ? FontStyle.italic : FontStyle.normal,
                    decoration: run.underline
                        ? TextDecoration.underline
                        : TextDecoration.none,
                    color: Color(run.color),
                    fontSize: run.fontSize,
                    fontFamily: run.fontFamily,
                    backgroundColor: run.backgroundColor == null
                        ? null
                        : Color(run.backgroundColor!),
                  ),
                ),
            ],
          );
    runsLeft -= span.children!.length;
    if (runsLeft < 0) {
      throw subtitleFailure(YlFailureCodes.subtitleTooLarge);
    }
    text.add(span);
  }
  return _Document(doc, text);
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
