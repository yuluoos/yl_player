/// Release every owned fixture resource; preserve an existing playback failure.
Future<void> releaseBoundResources(
  List<Future<void> Function()> steps, {
  required bool preserveFailure,
}) async {
  Object? firstError;
  StackTrace? firstStack;
  for (final step in steps) {
    try {
      await step();
    } catch (error, stack) {
      firstError ??= error;
      firstStack ??= stack;
    }
  }
  if (!preserveFailure && firstError != null) {
    Error.throwWithStackTrace(firstError, firstStack!);
  }
}
