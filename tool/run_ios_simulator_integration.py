"""Run the existing integration driver without racing simulator log streaming."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.parse import urlsplit


def service_uri(records, pid):
    for record in reversed(records):
        if record.get('processID') != pid:
            continue
        match = re.search(r'The Dart VM service is listening on (http://\S+)',
                          record.get('eventMessage', ''))
        if not match:
            continue
        uri = match.group(1)
        parsed = urlsplit(uri)
        if (parsed.hostname not in ('127.0.0.1', 'localhost', '::1') or
                not parsed.port or parsed.username or parsed.password or
                parsed.query or parsed.fragment or parsed.path in ('', '/')):
            raise ValueError('VM Service must be authenticated and local')
        return uri
    return None


def validate_results(path):
    cases = json.loads(path.read_text()).get('ciCases')
    if not isinstance(cases, dict) or not cases or any(v != 'success' for v in cases.values()):
        raise ValueError('Missing or nonpassing integration case receipt')
    print(json.dumps({'passed': len(cases), 'cases': sorted(cases)}), flush=True)


def terminate_after_test(run, simulator, bundle):
    # Cleanup must not replace the driver's exit code (or its original error).
    try:
        run(['xcrun', 'simctl', 'terminate', simulator, bundle],
            timeout=15, capture=True, check=False)
    except (subprocess.TimeoutExpired, OSError) as error:
        print(f'Test application cleanup did not finish: {error}', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--test', required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    args = parser.parse_args()
    example = Path(__file__).resolve().parents[1] / 'packages/yl_player/example'
    target = (example / args.test).resolve(strict=True)
    if target.parent != example / 'integration_test' or target.suffix != '.dart':
        raise ValueError('Expected an example integration test')
    evidence = args.evidence.resolve() / target.stem
    evidence.mkdir(parents=True, exist_ok=True)
    bundle = 'dev.ylplayer.ylPlayerExample'

    def run(command, timeout=60, capture=False, check=True, env=None):
        print('+ ' + ' '.join(command), flush=True)
        return subprocess.run(command, cwd=example, timeout=timeout, check=check,
                              text=True, capture_output=capture, env=env)

    # The future callback is registered before the driver awaits completion.
    # Preserve the executed test names, including failures, in the driver data.
    with tempfile.TemporaryDirectory(prefix='yl-ios-ci-', dir=example / '.dart_tool') as directory:
        entry = Path(directory) / 'entry.dart'
        entry.write_text("""import 'dart:async';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart' show setUp, tearDown;
import 'package:test_api/scaffolding.dart' show Timeout;
import 'package:integration_test/integration_test.dart';
import '__YL_TEST_URI__' as suite;

// iOS can enable platform semantics after a test records its leak baseline.
// SemanticsBinding owns exactly one handle while platform semantics is enabled.
// Keep real handles untouched and report test/application-owned handles to the
// normal WidgetTester leak check; a platform request is not a test-owned leak.
class CiIntegrationBinding extends IntegrationTestWidgetsFlutterBinding {
  final semanticsObservations = <Map<String, Object?>>[];

  @override
  int get debugOutstandingSemanticsHandles {
    final owned = super.debugOutstandingSemanticsHandles -
        (platformDispatcher.semanticsEnabled ? 1 : 0);
    assert(owned >= 0, 'Platform semantics ownership is inconsistent');
    return owned;
  }

  void recordSemantics(String phase, {String? stack}) {
    semanticsObservations.add({
      'phase': phase,
      'allHandles': super.debugOutstandingSemanticsHandles,
      'testOwnedHandles': debugOutstandingSemanticsHandles,
      'platformEnabled': platformDispatcher.semanticsEnabled,
      if (stack != null) 'stack': stack,
    });
  }

  @override
  SemanticsHandle ensureSemantics() {
    final handle = super.ensureSemantics();
    recordSemantics('ensureSemantics', stack: StackTrace.current.toString());
    return handle;
  }
}

void main() {
  final binding = CiIntegrationBinding();
  binding.defaultTestTimeout = const Timeout(Duration(minutes: 5));
  setUp(() => binding.recordSemantics('setUp'));
  tearDown(() => binding.recordSemantics('tearDown'));
  unawaited(binding.allTestsPassed.future.then((_) {
    binding.recordSemantics('suiteComplete');
    binding.reportData = {...?binding.reportData,
      'ciSemantics': binding.semanticsObservations,
      'ciCases': binding.results.map((name, result) => MapEntry(name, result.toString()))};
  }));
  suite.main();
}
""".replace('__YL_TEST_URI__', target.as_uri()))
        driver = Path(directory) / 'driver.dart'
        driver.write_text("import 'package:integration_test/integration_test_driver.dart';\n"
                          "Future<void> main() => integrationDriver(writeResponseOnFailure: true);\n")
        run(['flutter', 'build', 'ios', '--no-pub', '--simulator', '--debug', '--target', str(entry)], timeout=600)
        run(['xcrun', 'simctl', 'install', args.simulator, 'build/ios/iphonesimulator/Runner.app'])
        launched = run(['xcrun', 'simctl', 'launch', '--terminate-running-process', args.simulator, bundle,
                        '--enable-dart-profiling', '--disable-vm-service-publication',
                        '--enable-checked-mode', '--verify-entry-points'], capture=True)
        (evidence / 'launch.log').write_text(launched.stdout + launched.stderr)
        match = re.search(r'^' + re.escape(bundle) + r': (\d+)\s*$', launched.stdout, re.MULTILINE)
        if not match:
            raise ValueError('Simulator did not report the launched process')
        pid = int(match.group(1))
        try:
            deadline = time.monotonic() + 60
            uri = None
            while uri is None and time.monotonic() < deadline:
                # A cold Simulator logd query can take longer than 15 seconds.
                # Use the remaining discovery budget, rather than failing before
                # the existing 60-second overall deadline has been exhausted.
                result = run(['xcrun', 'simctl', 'spawn', args.simulator, 'log', 'show',
                              '--last', '2m', '--style', 'json', '--predicate',
                              f'processIdentifier == {pid} AND eventMessage CONTAINS "The Dart VM service is listening on"'],
                             capture=True, timeout=max(0.001, deadline - time.monotonic()))
                (evidence / 'vm-service.json').write_text(result.stdout)
                uri = service_uri(json.loads(result.stdout), pid)
                if uri is None:
                    time.sleep(1)
            if uri is None:
                raise TimeoutError('Current test process did not expose VM Service within 60 seconds')
            receipt = evidence / 'integration_response_data.json'
            receipt.unlink(missing_ok=True)
            env = dict(os.environ, FLUTTER_TEST_OUTPUTS_DIR=str(evidence))
            driven = run(['flutter', 'drive', '--no-pub', '-d', args.simulator,
                          '--driver', str(driver), '--target', str(entry),
                          '--use-existing-app', uri, '--no-keep-app-running', '--timeout', '1200'],
                         timeout=1230, check=False, env=env)
            if driven.returncode:
                raise SystemExit(driven.returncode)
            validate_results(receipt)
        finally:
            terminate_after_test(run, args.simulator, bundle)


if __name__ == '__main__':
    main()
