/// Removes only the owned MPD total and final Period duration for playback tests.
String omitFinalDashDuration(String manifest) {
  final starts = RegExp(r'<Period\b[^>]*>').allMatches(manifest).toList();
  if (starts.isEmpty) throw StateError('Expected owned Period fixture');
  final last = starts.last;
  final withoutFinal = manifest.replaceRange(
    last.start,
    last.end,
    last.group(0)!.replaceFirst(RegExp(r' duration="[^"]*"'), ''),
  );
  return withoutFinal.replaceFirst(
    RegExp(r' mediaPresentationDuration="[^"]*"'),
    '',
  );
}
