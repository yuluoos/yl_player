"""Execute the simulator and physical-device partitions of the existing playback suites."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
EXAMPLE = ROOT / 'packages/yl_player/example'
MANIFEST = Path(__file__).with_name('ci_playback') / 'cases.json'


def flutter_cases(platform, suite, target):
    entry = json.loads(MANIFEST.read_text())[platform][suite]
    cases = entry[target] + entry.get('both', [])
    all_cases = entry['physical'] + entry['simulator'] + entry.get('both', [])
    if len(set(all_cases)) != len(all_cases):
        raise ValueError(f'Duplicate CI case in {suite}')
    return cases


def name_filter(cases, exclude=False):
    alternatives = '(?:' + '|'.join(re.escape(name) for name in cases) + ')$'
    return '^(?!' + alternatives + ').*' if exclude else '^' + alternatives


def verify_cases(expected, observed):
    if not expected or sorted(expected) != sorted(observed):
        raise ValueError(f'Playback case mismatch: expected={sorted(expected)}, observed={sorted(observed)}')


def verify_flutter_report(report, expected):
    names = {}
    passed = []
    done = None
    with report.open() as stream:
        for line in stream:
            event = json.loads(line)
            if event['type'] == 'testStart':
                test = event['test']
                names[test['id']] = test['name']
            elif event['type'] == 'testDone' and not event['hidden']:
                if event['result'] != 'success' or event.get('skipped'):
                    raise ValueError(f'Nonpassing playback case: {names[event["testID"]]}')
                passed.append(names[event['testID']])
            elif event['type'] == 'done':
                done = event['success']
    if done is not True:
        raise ValueError('Missing successful Flutter completion')
    verify_cases(expected, passed)


def verify_device(platform, device, target):
    devices = json.loads(subprocess.check_output(['flutter', 'devices', '--machine']))
    matched = [d for d in devices if d['id'] == device and
               d['targetPlatform'].split('-')[0] == platform]
    expected_emulator = target == 'simulator'
    if len(matched) != 1 or matched[0].get('emulator') is not expected_emulator:
        raise ValueError(f'Required {platform} {target} is unavailable: {device}')
    identity = {'target': target, 'platform': matched[0]['targetPlatform']}
    if platform == 'android':
        api = subprocess.check_output(['adb', '-s', device, 'shell', 'getprop', 'ro.build.version.sdk'], text=True)
        if api.strip() != '24':
            raise ValueError('Physical and emulator API 24 partitions both require SDK 24')
        identity['apiLevel'] = 24
    return identity


def ios_native(target, device, evidence):
    sys.path.insert(0, str(ROOT / 'tool/consumer_fixtures/apple_flutter'))
    from main_example_tests import expected_identities, verify_current_targets, verify_result_bundle

    verify_current_targets(ROOT)
    canonical = expected_identities(ROOT / 'tool/consumer_fixtures/apple_flutter', 'ios')
    listed = json.loads(MANIFEST.read_text())['iosNativePhysical']
    physical = set(listed)
    if not physical or len(physical) != len(listed) or not physical < canonical:
        raise ValueError('Invalid physical XCTest inventory')
    simulator = target == 'simulator'
    selected = canonical - physical if simulator else physical
    platform = 'iOS Simulator' if simulator else 'iOS'
    sdk = 'iphonesimulator' if simulator else 'iphoneos'
    action = 'skip' if simulator else 'only'
    bundle = evidence / 'native.xcresult'
    command = ['xcodebuild', 'test', '-quiet', '-sdk', sdk, '-workspace', 'ios/Runner.xcworkspace',
               '-scheme', 'Runner', '-parallel-testing-enabled', 'NO', '-destination',
               f'platform={platform},id={device}', '-resultBundlePath', str(bundle),
               '-derivedDataPath', str(EXAMPLE / 'build' / ('native-ios-' + target)),
               'ENABLE_TESTABILITY=YES', 'CODE_SIGNING_ALLOWED=' + ('NO' if simulator else 'YES')]
    if not simulator and os.environ.get('YL_IOS_DEVELOPMENT_TEAM'):
        command.append('DEVELOPMENT_TEAM=' + os.environ['YL_IOS_DEVELOPMENT_TEAM'])
    command.extend(f'-{action}-testing:RunnerTests/{case[:-2]}' for case in sorted(physical))
    with (evidence / 'native.log').open('w') as log:
        result = subprocess.run(command, cwd=EXAMPLE, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((evidence / 'native.log').read_text(errors='replace')[-16000:], flush=True)
    runtime = evidence / 'runtime'
    verify_result_bundle(ROOT, bundle, 'ios', runtime, selected)
    observed = json.loads((runtime / 'tests.json').read_text())['devices']
    if len(observed) != 1 or observed[0]['platform'] != platform:
        raise ValueError('XCTest ran on the wrong device type')
    receipt = json.loads((runtime / 'case-identities.json').read_text())
    if not simulator and receipt['skipped']:
        raise ValueError('Physical hardware XCTest was skipped')
    result.check_returncode()


def ios_flutter(target, device, evidence):
    failed = []
    for suite in json.loads(MANIFEST.read_text())['ios']:
        cases = flutter_cases('ios', suite, target)
        if not cases:
            continue
        path = 'integration_test/' + suite + '.dart'
        if target == 'simulator':
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'tool/run_ios_simulator_integration.py'),
                            '--simulator', device, '--test', path, '--evidence', str(evidence),
                            '--ci-partition'])
            if result.returncode and not (evidence / suite / 'integration_response_data.json').is_file():
                result.check_returncode()
        else:
            report = evidence / (suite + '.jsonl')
            result = subprocess.run(['flutter', 'test', path, '-d', device, '--no-pub', '--name',
                            name_filter(cases), '--file-reporter', 'json:' + str(report),
                            '--dart-define=YL_CI_REQUIRE_HARDWARE=true', '--reporter', 'expanded'],
                           cwd=EXAMPLE)
            if result.returncode:
                from run_android_integration import completed_case_failure
                if not completed_case_failure(report):
                    result.check_returncode()
            else:
                verify_flutter_report(report, cases)
        if result.returncode:
            failed.append(suite)
    if failed:
        raise SystemExit('Failed iOS playback suites: ' + ', '.join(failed))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['verify-ios', 'verify-android', 'ios-native', 'ios-flutter'])
    parser.add_argument('target', choices=['simulator', 'physical'])
    parser.add_argument('device')
    parser.add_argument('--evidence', type=Path)
    args = parser.parse_args()
    if args.command.startswith('verify-'):
        identity = verify_device(args.command.removeprefix('verify-'), args.device, args.target)
        print('Verified playback target:', json.dumps(identity), flush=True)
        if args.evidence:
            (args.evidence / 'target.json').write_text(json.dumps(identity, indent=2) + '\n')
    else:
        if not args.evidence:
            parser.error('--evidence is required')
        run = ios_native if args.command == 'ios-native' else ios_flutter
        run(args.target, args.device, args.evidence.resolve())
