import 'dart:convert';
import 'dart:io';
import '../../packages/yl_player/example/integration_test/support/drm_acceptance_case.dart';

/// Offline only: never probes a URL or posts a license challenge.
void main(List<String> args) {
  try {
    if (args.length != 1 && args.length != 3) throw const FormatException();
    final input = File(args[0]);
    if (input.lengthSync() > 1024 * 1024) throw const FormatException();
    final now = DateTime.now().toUtc();
    final cases = inspectDrmInventory(input.readAsStringSync(), now: now);
    final selected = args.length == 3
        ? cases.singleWhere((value) => value.caseId == args[1])
        : null;
    final missing = selected != null
        ? selected.missing.isNotEmpty
        : cases.any((value) => value.missing.isNotEmpty);
    if (!missing && selected != null) {
      // A fixed ignored root, owner-only permissions, and exclusive output keep
      // secrets out of checked-in files and prevent accidentally reusing a run.
      if (!Platform.isMacOS && !Platform.isLinux) throw const FormatException();
      final repository = File.fromUri(Platform.script).parent.parent.parent;
      final private = Directory('${repository.path}/.drm-acceptance-private');
      final type = FileSystemEntity.typeSync(private.path, followLinks: false);
      if (type != FileSystemEntityType.directory &&
          type != FileSystemEntityType.notFound) {
        throw const FormatException();
      }
      private.createSync();
      if (Process.runSync('chmod', ['700', private.path]).exitCode != 0) {
        throw const FormatException();
      }
      final output = File(args[2]).absolute;
      if (output.parent.resolveSymbolicLinksSync() !=
          private.resolveSymbolicLinksSync()) {
        throw const FormatException();
      }
      output.createSync(exclusive: true);
      try {
        if (Process.runSync('chmod', ['600', output.path]).exitCode != 0) {
          throw const FormatException();
        }
        output.writeAsStringSync(
          jsonEncode({
            'YL_DRM_CASE': jsonEncode(selected.runtimeDefinition(now: now)),
          }),
          flush: true,
        );
      } on Object catch (_) {
        output.deleteSync();
        rethrow;
      }
    }
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': 1,
        'stage': 'resource_preflight',
        'selectedCase': selected?.caseId,
        'networkRequests': 0,
        'cases': cases.map((value) => value.report).toList(),
      }),
    );
    exitCode = missing ? 2 : 0;
  } on Object catch (_) {
    // No exception text, input path, URL, header or binary bytes in diagnostics.
    stdout.writeln(
      '{"stage":"resource_preflight","verification":"failed","code":"drm.acceptance_config_invalid"}',
    );
    exitCode = 2;
  }
}
