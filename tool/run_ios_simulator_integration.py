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


def launch_test_app(run, simulator, bundle, log_path):
    command = ['xcrun', 'simctl', 'launch', '--terminate-running-process', simulator, bundle,
               '--enable-dart-profiling', '--disable-vm-service-publication',
               '--enable-checked-mode', '--verify-entry-points']
    pid_line = re.compile(r'^' + re.escape(bundle) + r': ([1-9]\d*)[ \t]*\r?\n', re.MULTILINE)
    with log_path.open('w') as log:
        for attempt in (1, 2):
            print(f'Launch attempt {attempt}', file=log, flush=True)
            try:
                result = run(command, capture=True, check=False)
            except subprocess.TimeoutExpired as error:
                # TimeoutExpired carries bytes even when subprocess.run uses text=True.
                stdout = (error.stdout or b'').decode(errors='replace')
                stderr = (error.stderr or b'').decode(errors='replace')
                print(stdout, stderr, str(error), sep='\n', file=log, flush=True)
                match = pid_line.search(stdout)
                if match:
                    return int(match.group(1))
                if attempt == 2:
                    raise
                # CoreSimulator can still be finishing a cold launch. Wait for
                # the same device, then replace any partially launched instance.
                run(['xcrun', 'simctl', 'bootstatus', simulator, '-b'], timeout=120)
            else:
                print(result.stdout, result.stderr, sep='\n', file=log)
                result.check_returncode()
                match = pid_line.search(result.stdout + '\n')
                if not match:
                    raise ValueError('Simulator did not report the launched process')
                return int(match.group(1))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator', required=True)
    parser.add_argument('--test', required=True)
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--ci-partition', action='store_true')
    args = parser.parse_args()
    example = Path(__file__).resolve().parents[1] / 'packages/yl_player/example'
    target = (example / args.test).resolve(strict=True)
    if target.parent != example / 'integration_test' or target.suffix != '.dart':
        raise ValueError('Expected an example integration test')
    evidence = args.evidence.resolve() / target.stem
    evidence.mkdir(parents=True, exist_ok=True)
    receipt = evidence / 'integration_response_data.json'
    receipt.unlink(missing_ok=True)
    bundle = 'dev.ylplayer.ylPlayerExample'

    def run(command, timeout=60, capture=False, check=True, env=None):
        print('+ ' + ' '.join(command), flush=True)
        return subprocess.run(command, cwd=example, timeout=timeout, check=check,
                              text=True, capture_output=capture, env=env)

    # The future callback is registered before the driver awaits completion.
    # Preserve the executed test names, including failures, in the driver data.
    with tempfile.TemporaryDirectory(prefix='yl-ios-ci-', dir=example / '.dart_tool') as directory:
        entry = Path(directory) / 'entry.dart'
        registration_import = ''
        registration_setup = ''
        if args.ci_partition:
            from ci_playback_shards import MANIFEST, flutter_cases, verify_cases
            physical = json.loads(MANIFEST.read_text())['ios'][target.stem]['physical']
            registration = target.parent / 'support/ci_playback_registration.dart'
            registration_import = f"import '{registration.as_uri()}' as registration;"
            case_literals = ', '.join(json.dumps(name, ensure_ascii=False).replace('$', r'\$')
                                      for name in physical)
            registration_setup = f'registration.physicalOnlyCases = <String>{{{case_literals}}};'
        entry.write_text("""import 'dart:async';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart' show setUp, tearDown;
import 'package:test_api/scaffolding.dart' show Timeout;
import 'package:integration_test/integration_test.dart';
import '__YL_TEST_URI__' as suite;
__YL_REGISTRATION_IMPORT__

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
  __YL_REGISTRATION_SETUP__
  suite.main();
}
""".replace('__YL_TEST_URI__', target.as_uri()).replace('__YL_REGISTRATION_IMPORT__', registration_import)
           .replace('__YL_REGISTRATION_SETUP__', registration_setup))
        driver = Path(directory) / 'driver.dart'
        driver.write_text("import 'package:integration_test/integration_test_driver.dart';\n"
                          "Future<void> main() => integrationDriver(writeResponseOnFailure: true);\n")
        build = ['flutter', 'build', 'ios', '--no-pub', '--simulator', '--debug', '--target', str(entry)]
        if args.ci_partition:
            build.append('--config-only')
        run(build, timeout=600)
        app = example / 'build/ios/iphonesimulator/Runner.app'
        if args.ci_partition:
            # Compile for the verified Simulator destination. A generic build
            # can request both arm64 and x86_64 even on an arm64-only runner.
            derived = example / 'build/native-ios-simulator'
            run(['xcodebuild', 'build', '-quiet', '-workspace', 'ios/Runner.xcworkspace',
                 '-scheme', 'Runner', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
                 '-destination', 'platform=iOS Simulator,id=' + args.simulator,
                 '-derivedDataPath', str(derived), 'CODE_SIGNING_ALLOWED=NO',
                 'ONLY_ACTIVE_ARCH=YES'], timeout=600)
            app = derived / 'Build/Products/Debug-iphonesimulator/Runner.app'
        run(['xcrun', 'simctl', 'install', args.simulator, str(app)])
        try:
            pid = launch_test_app(run, args.simulator, bundle, evidence / 'launch.log')
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
            env = dict(os.environ, FLUTTER_TEST_OUTPUTS_DIR=str(evidence))
            driven = run(['flutter', 'drive', '--no-pub', '-d', args.simulator,
                          '--driver', str(driver), '--target', str(entry),
                          '--use-existing-app', uri, '--no-keep-app-running', '--timeout', '1200'],
                         timeout=1230, check=False, env=env)
            if driven.returncode:
                raise SystemExit(driven.returncode)
            validate_results(receipt)
            if args.ci_partition:
                verify_cases(flutter_cases('ios', target.stem, 'simulator'),
                             json.loads(receipt.read_text())['ciCases'])
        finally:
            terminate_after_test(run, args.simulator, bundle)


if __name__ == '__main__':
    main()
