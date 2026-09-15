"""Verify the endorsed example tests and their immutable migration origins.

Historical checks require the pinned pre-endorsement commit to exist locally.
The check never fetches repository history; shallow checkouts must fetch exactly
that commit before invoking it.
"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


PINNED_REVISION = "ce368c55ad291b163b02157b487dbbf798a69892"
HISTORICAL_MANIFESTS = {
    "tests-manifest.json": PINNED_REVISION,
    "engine-tests-manifest.json": PINNED_REVISION,
    "resources-manifest.json": PINNED_REVISION,
}
EXPECTED_CASES = {"ios": 404, "macos": 346}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def require_revision(root, revision=PINNED_REVISION):
    result = subprocess.run(
        ["git", "-C", str(root), "cat-file", "-e", f"{revision}^{{commit}}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if result.returncode:
        raise RuntimeError(
            "missing pinned historical revision "
            f"{revision}; shallow checkouts must run: "
            f"git fetch --no-tags --depth=1 origin {revision}"
        )


def git_blob(root, revision, path):
    require_revision(root, revision)
    result = subprocess.run(
        ["git", "-C", str(root), "show", f"{revision}:{path}"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise RuntimeError(
            f"historical fixture is missing at {revision}:{path}: "
            f"{result.stderr.decode(errors='replace').strip()}"
        )
    return result.stdout


def source_bytes(root, manifest_name, row):
    revision = HISTORICAL_MANIFESTS.get(manifest_name)
    if revision is not None:
        return git_blob(root, revision, row["source"])
    return (root / row["source"]).read_bytes()


def verify_historical_sources(root):
    root = Path(root).resolve()
    fixtures = root / "tool/consumer_fixtures/apple_flutter"
    require_revision(root)
    for manifest_name in HISTORICAL_MANIFESTS:
        rows = json.loads((fixtures / manifest_name).read_text())
        for row in rows:
            expected = row.get(
                "source_sha256", row.get("original_sha256", row.get("sha256"))
            )
            actual = digest(source_bytes(root, manifest_name, row))
            if actual != expected:
                raise RuntimeError(
                    f"historical source hash changed at {PINNED_REVISION}:"
                    f"{row['source']}: expected {expected}, got {actual}"
                )

        for row in rows:
            original = source_bytes(root, manifest_name, row)
            for retired in row.get("retired_methods", []):
                body = retired["original_body"].encode()
                if digest(body) != retired["original_body_sha256"]:
                    raise RuntimeError(
                        f"retired method body hash changed: {retired['method']}"
                    )
                if body not in original:
                    raise RuntimeError(
                        f"retired method body is absent from pinned source: "
                        f"{retired['method']}"
                    )

    for row in json.loads((fixtures / "task7-host-cases.json").read_text()):
        body = row["original_body"].encode()
        if digest(body) != row["original_body_sha256"]:
            raise RuntimeError(f"host transfer body hash changed: {row['method']}")
        if body not in git_blob(root, PINNED_REVISION, row["source"]):
            raise RuntimeError(
                f"host transfer body is absent from pinned source: "
                f"{row['source']}::{row['method']}"
            )


def accepted_tests(fixtures, platform):
    paths = list((fixtures / "RunnerTests").glob("*.swift"))
    paths += list((fixtures / f"RunnerTests-{platform}").glob("*.swift"))
    accepted = {}
    for path in paths:
        if path.name in accepted:
            raise RuntimeError(f"duplicate accepted fixture filename: {path.name}")
        accepted[path.name] = path.read_bytes()
    return accepted


def verify_current_targets(root):
    root = Path(root).resolve()
    fixtures = root / "tool/consumer_fixtures/apple_flutter"
    skip_contracts = json.loads((fixtures / 'allowed-hardware-skips.json').read_text())['conditions']
    for identity, contract in skip_contracts.items():
        if digest((fixtures / contract['source']).read_bytes()) != contract['source_sha256']:
            raise RuntimeError(f'Historical skip source requires explicit condition reconciliation: {identity}')
    resources = {
        path.name: path.read_bytes()
        for path in (fixtures / "Resources").iterdir()
        if path.is_file()
    }
    for platform, expected_count in EXPECTED_CASES.items():
        target = root / f"packages/yl_player/example/{platform}/RunnerTests"
        accepted = accepted_tests(fixtures, platform)
        verify_pbx_membership((target.parent / 'Runner.xcodeproj/project.pbxproj').read_text(), set(accepted))
        actual = {path.name: path.read_bytes() for path in target.glob("*.swift")}
        if actual != accepted:
            missing = sorted(set(accepted) - set(actual))
            extra = sorted(set(actual) - set(accepted))
            changed = sorted(
                name
                for name in set(actual) & set(accepted)
                if actual[name] != accepted[name]
            )
            raise RuntimeError(
                f"{platform} example tests differ from accepted fixtures: "
                f"missing={missing}, extra={extra}, changed={changed}"
            )
        actual_resources = {
            path.name: path.read_bytes()
            for path in target.iterdir()
            if path.is_file() and path.suffix != ".swift"
        }
        if actual_resources != resources:
            raise RuntimeError(
                f"{platform} example test resources differ from accepted fixtures"
            )
        text = b"\n".join(actual.values()).decode()
        count = len(re.findall(r"\bfunc test\w+\(", text))
        if count != expected_count:
            raise RuntimeError(
                f"{platform} example expected {expected_count} native cases, got {count}"
            )
        if "@testable import yl_player_ios" in text or "@testable import yl_player_macos" in text:
            raise RuntimeError(f"{platform} example retains a legacy testable import")
        if "@testable import yl_player_apple" not in text:
            raise RuntimeError(f"{platform} example does not test yl_player_apple")


R19_CASE = 'YlManagedFallbackCharacterizationTests/testBoundedSixteenMiBRealManagedFixtureProgressMetricsAndEOF()'
R19_REASON = 'Test skipped - Task4 actual H264 hardware fixture: simulator VTIsHardwareDecodeSupported=false; physical iOS evidence pending (R19).'


def case_nodes(nodes):
    for node in nodes:
        if node.get('nodeType') == 'Test Case':
            yield node
        yield from case_nodes(node.get('children', []))


def platform_source(text, platform):
    # Resolve compilation conditions, including methods that exist on only one
    # Apple platform. Unknown conditions fail closed rather than inventing cases.
    active = [True]; conditions = []
    output = []
    for line in text.splitlines():
        token = line.strip()
        if token.startswith('#if '):
            expression = token[4:]
            values = {'os(iOS)': platform == 'ios', 'os(macOS)': platform == 'macos', 'targetEnvironment(simulator)': platform == 'ios'}
            if expression not in values:
                raise RuntimeError(f'Unresolved XCTest compilation condition: {expression}')
            conditions.append(values[expression]); active.append(active[-1] and conditions[-1])
        elif token == '#else':
            active[-1] = active[-2] and not conditions[-1]
        elif token == '#endif':
            active.pop(); conditions.pop()
        elif token.startswith('#elseif'):
            raise RuntimeError('Unresolved XCTest elseif condition')
        elif active[-1]:
            output.append(line)
    if len(active) != 1:
        raise RuntimeError('Unbalanced XCTest compilation condition')
    return '\n'.join(output)


def expected_identities(fixtures, platform):
    identities = []
    for name, data in accepted_tests(fixtures, platform).items():
        text = platform_source(data.decode(), platform)
        classes = list(re.finditer(r'class (\w+)\s*:\s*XCTestCase', text))
        for method in re.finditer(r'\bfunc (test\w+)\(', text):
            owners = [owner for owner in classes if owner.start() < method.start()]
            if not owners:
                raise RuntimeError(f'XCTest method without class: {name}')
            identities.append(owners[-1].group(1) + '/' + method.group(1) + '()')
    if len(identities) != len(set(identities)):
        raise RuntimeError('duplicate canonical XCTest identity')
    return set(identities)


def verify_pbx_membership(pbx, expected):
    # Bind the actual RunnerTests target to its Sources phase, then to build-file
    # references. Filenames mentioned in another target do not count as membership.
    objects = dict(re.findall(r'^\t\t([A-F0-9]{24}) /\*[^\n]*?\*/ = \{(.*?)(?=^\t\t[A-F0-9]{24} /\*|^/\* End|\Z)', pbx, re.M | re.S))
    targets = [body for body in objects.values() if 'isa = PBXNativeTarget;' in body and re.search(r'\bname = RunnerTests;', body)]
    if len(targets) != 1:
        raise RuntimeError('missing or ambiguous RunnerTests PBX target')
    phases = re.search(r'buildPhases = \((.*?)\);', targets[0], re.S)
    source_phases = [objects[key] for key in re.findall(r'\b[A-F0-9]{24}\b', phases.group(1)) if 'isa = PBXSourcesBuildPhase;' in objects[key]]
    if len(source_phases) != 1:
        raise RuntimeError('missing or ambiguous RunnerTests Sources phase')
    names = re.findall(r'/\* ([^*]+\.swift) in Sources \*/', source_phases[0])
    if len(names) != len(set(names)) or set(names) != expected:
        raise RuntimeError(f'RunnerTests PBX membership differs: missing={expected-set(names)}, extra={set(names)-expected}')
    groups = [body for body in objects.values() if 'isa = PBXGroup;' in body and re.search(r'\bpath = RunnerTests;', body)]
    if len(groups) != 1:
        raise RuntimeError('missing or ambiguous RunnerTests source group')
    for key in re.findall(r'\b[A-F0-9]{24}\b', source_phases[0]):
        build = objects.get(key, '')
        match = re.search(r'fileRef = ([A-F0-9]{24}) /\* ([^*]+) \*/;', build)
        if not match or match.group(1) not in groups[0] or match.group(2) not in expected or f'path = {match.group(2)};' not in objects.get(match.group(1), ''):
            raise RuntimeError('RunnerTests Sources entry has invalid file reference')


def verify_runtime(tree, summary, expected, platform, evidence=None):
    nodes = list(case_nodes(tree['testNodes']))
    ids = [node['nodeIdentifier'] for node in nodes]
    if len(ids) != len(set(ids)):
        raise RuntimeError('duplicate XCTest execution identity')
    if set(ids) != expected:
        raise RuntimeError(f'Native case identities differ: missing={expected-set(ids)}, extra={set(ids)-expected}')
    counts = {result: sum(node['result'] == result for node in nodes) for result in ['Passed', 'Skipped', 'Failed']}
    if any(node['result'] not in {'Passed', 'Skipped'} for node in nodes):
        raise RuntimeError('Native XCTest contains nonpassing cases')
    fixtures = Path(__file__).resolve().parent
    allowed = set(json.loads((fixtures / 'allowed-hardware-skips.json').read_text())[platform])
    for node in nodes:
        if node['result'] != 'Skipped':
            continue
        identity = node['nodeIdentifier']
        if identity not in allowed:
            raise RuntimeError(f'Unexpected XCTest skip: {identity}')
        reason = '\n'.join(child.get('name', '') for child in node.get('children', []))
        proof = (evidence or {}).get(identity, {})
        if identity == R19_CASE:
            if reason != R19_REASON:
                raise RuntimeError('R19 skip reason changed')
            if proof.get('platform') != 'iOS Simulator' or proof.get('capability', '').strip() != 'fixture=h264_aac.mkv subtype=1635148593 h264=1635148593 hardwareAvailable=false controlledVideo=false':
                raise RuntimeError('R19 skip lacks exact Simulator H264 runtime capability attachment')
        else:
            reasons = json.loads((fixtures / 'allowed-hardware-skips.json').read_text())['conditions']
            if reason != 'Test skipped - ' + reasons[identity]['message'] or proof.get('platform') != 'iOS Simulator':
                raise RuntimeError(f'Historical hardware skip condition changed: {identity}')
    actual_summary = {'totalTestCount': len(nodes), 'passedTests': counts['Passed'], 'skippedTests': counts['Skipped'], 'failedTests': 0}
    if any(summary.get(key) != value for key, value in actual_summary.items()):
        raise RuntimeError(f'XCTest summary disagrees with executed identities: {actual_summary}')
    return {'expected': sorted(expected), 'observed': sorted(ids), 'skipped': sorted(n['nodeIdentifier'] for n in nodes if n['result'] == 'Skipped'), 'summary': actual_summary}


def verify_result_bundle(root, result, platform, output, selected=None):
    output = Path(output); output.mkdir(parents=True, exist_ok=True)
    def fetch(kind, *extra):
        data = subprocess.check_output(['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(result), *extra])
        return json.loads(data)
    tree = fetch('tests'); summary = fetch('summary')
    (output / 'tests.json').write_text(json.dumps(tree, indent=2) + '\n')
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    expected = expected_identities(Path(root) / 'tool/consumer_fixtures/apple_flutter', platform)
    if selected is not None:
        if not set(selected) <= expected:
            raise RuntimeError('selected runtime case is not canonical')
        expected = set(selected)
    evidence = {}
    for node in case_nodes(tree['testNodes']):
        if node['result'] != 'Skipped':
            continue
        identity = node['nodeIdentifier']; activities = fetch('activities', '--test-id', identity)
        safe = re.sub(r'[^A-Za-z0-9_-]', '_', identity)
        (output / f'{safe}-activities.json').write_text(json.dumps(activities, indent=2) + '\n')
        runs = activities.get('testRuns', [])
        if len(runs) != 1:
            raise RuntimeError('skip must have exactly one observed runtime')
        proof = {'platform': runs[0]['device']['platform']}
        if identity == R19_CASE:
            attachments = output / f'{safe}-attachments'
            subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--test-id', identity, '--output-path', str(attachments)], check=True)
            manifest = json.loads((attachments / 'manifest.json').read_text())
            payloads = [a for item in manifest if item['testIdentifier'] == identity for a in item['attachments'] if a['suggestedHumanReadableName'].startswith('Task4-video-capability_')]
            if len(payloads) != 1:
                raise RuntimeError('R19 capability attachment missing or ambiguous')
            proof['capability'] = (attachments / payloads[0]['exportedFileName']).read_text()
        evidence[identity] = proof
    receipt = verify_runtime(tree, summary, expected, platform, evidence)
    receipt.update(result_bundle=str(Path(result).resolve()), platform=platform, coverage='focused selection' if selected else 'complete canonical suite', skip_evidence=evidence)
    (output / 'case-identities.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt['summary']))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--historical-only", action="store_true")
    group.add_argument("--current-only", action="store_true")
    parser.add_argument('--result-bundle')
    parser.add_argument('--platform', choices=['ios', 'macos'])
    parser.add_argument('--output')
    parser.add_argument('--selected-case', action='append', help='Focused evidence only; never used by a full gate')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    if args.result_bundle:
        if not args.platform or not args.output:
            parser.error('--result-bundle requires --platform and --output')
        verify_current_targets(root)
        verify_result_bundle(root, args.result_bundle, args.platform, args.output, args.selected_case)
        return
    if not args.current_only:
        verify_historical_sources(root)
        print(f"Historical Apple test provenance: {PINNED_REVISION} verified")
    if not args.historical_only:
        verify_current_targets(root)
        print(f"Current Apple example tests: iOS {EXPECTED_CASES['ios']}, macOS {EXPECTED_CASES['macos']} verified")


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as error:
        raise SystemExit(str(error)) from error
