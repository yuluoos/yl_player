#!/usr/bin/env python3
"""Offline, source-bound coverage inventory. Inventory validity is not acceptance."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

PLATFORMS = ('android', 'ios', 'macos')
GATES = ('PERF-BASELINE', 'RELEASE-CONSUMERS', 'RELEASE-CI')
IMPLEMENTATION = ('unreviewed', 'not_implemented', 'partial', 'implemented')
VERIFICATION = ('not_run', 'external_missing', 'passed', 'failed', 'skipped')
TOKEN = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z')
SHA = re.compile(r'[0-9a-f]{64}\Z')
MAX_JSON = 1024 * 1024
MAX_FILE = 16 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
EXCLUDED = {'example', 'test', 'tests', 'Tests'}


def require(value):
    if not value:
        raise ValueError('invalid release inventory')


def fields(value, expected):
    require(isinstance(value, dict) and set(value) == set(expected.split()))


def token(value):
    require(isinstance(value, str) and TOKEN.fullmatch(value))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=True).encode()


def relative_path(value):
    require(isinstance(value, str) and 0 < len(value) <= 512)
    path = PurePosixPath(value)
    require(not path.is_absolute() and path.as_posix() == value)
    require(all(part not in ('', '.', '..') for part in value.split('/')))
    require(not any(ord(char) < 32 or char == '\\' for char in value))
    return path


def read_file(root, name, limit=MAX_FILE):
    path = relative_path(name)
    target = root
    for part in path.parts:
        target = target / part
        require(not target.is_symlink())
    require(target.is_file())
    with target.open('rb') as source:
        data = source.read(limit + 1)
    require(len(data) <= limit)
    return data


def pairs(values):
    result = {}
    for key, value in values:
        require(key not in result)
        result[key] = value
    return result


def reject_constant(_value):
    raise ValueError('invalid JSON')


def read_json(root, name):
    return json.loads(read_file(root, name, MAX_JSON), object_pairs_hook=pairs,
                      parse_constant=reject_constant)


def source_path(name):
    path = relative_path(name)
    return name in ('pubspec.yaml', 'pubspec.lock') or (
        path.parts[0] == 'packages' and not EXCLUDED.intersection(path.parts))


def source_snapshot(root):
    """All Git-visible package files except examples/tests, plus root dependency locks.

    Includes untracked nonignored additions. HEAD changes alone do not invalidate
    unchanged source; this is a source scope identity, not a runtime/build receipt.
    """
    root = Path(root).resolve(strict=True)
    result = subprocess.run(['git', 'ls-files', '-z', '--cached', '--others',
        '--exclude-standard', '--', 'packages', 'pubspec.yaml', 'pubspec.lock'],
        cwd=root, capture_output=True, timeout=30)
    require(result.returncode == 0 and len(result.stdout) <= 8*1024*1024)
    names = sorted(set(name.decode('utf-8') for name in result.stdout.split(b'\0') if name))
    require(len(names) <= 20000)
    scoped = {name for name in names if source_path(name)}
    files, total = {}, 0
    for name in names:
        if not source_path(name):
            continue
        # Tracked deletion is a source change, represented by absence from the map.
        if not (root/name).exists() and not (root/name).is_symlink():
            continue
        path = root/name
        if path.is_symlink():
            # Versioned framework links are part of the artifact identity. Their
            # target contents must also occur in this Git-visible source scope.
            target = path.resolve(strict=True).relative_to(root).as_posix()
            require(target in scoped or (path.is_dir() and
                    any(item.startswith(target+'/') for item in scoped)))
            data = canonical({'symlink': path.readlink().as_posix()})
        else:
            data = read_file(root, name)
        total += len(data)
        require(total <= MAX_TOTAL)
        files[name] = sha(data)
    return {'files': files, 'sha256': sha(canonical(files))}


def reference(root, value):
    fields(value, 'path sha256')
    require(isinstance(value['sha256'], str) and SHA.fullmatch(value['sha256']))
    data = read_file(root, value['path'])
    require(sha(data) == value['sha256'])
    return data


def requirements(data):
    ids = []
    for line in data.decode('utf-8').splitlines():
        match = re.match(r'^\|\s*((?:CAP|ERR|REG)-[A-Z0-9-]+)\s*(?:/[^|]*)?\|', line)
        if match:
            ids.append(match[1])
    require(ids and len(ids) <= 200 and len(set(ids)) == len(ids))
    require(all(any(item.startswith(prefix) for item in ids) for prefix in ('CAP-', 'ERR-', 'REG-')))
    return set(ids)


def acceptance(root, evidence, key, row, source_hash, requirements_hash):
    require(key in evidence and evidence[key]['kind'] == 'acceptance')
    value = read_json(root, evidence[key]['path'])
    fields(value, 'schemaVersion requirement platform sourceHash requirementsHash coverage outcome checks artifacts')
    require(type(value['schemaVersion']) is int and value['schemaVersion'] == 1)
    require(value['requirement'] == row['requirement'] and value['platform'] == row['platform'])
    require(value['sourceHash'] == source_hash and value['coverage'] == 'full' and value['outcome'] == 'passed')
    require(value['requirementsHash'] == requirements_hash)
    checks = value['checks']
    require(isinstance(checks, list) and 0 < len(checks) <= 1000)
    seen = set()
    for item in checks:
        fields(item, 'id outcome'); token(item['id'])
        require(item['id'] not in seen and item['outcome'] == 'passed')
        seen.add(item['id'])
    artifacts = value['artifacts']
    require(isinstance(artifacts, list) and 0 < len(artifacts) <= 100)
    seen = set()
    for artifact in artifacts:
        reference(root, artifact)
        require(artifact['path'] not in seen)
        seen.add(artifact['path'])


def check(root, manifest):
    root = Path(root).resolve(strict=True)
    fields(manifest, 'schemaVersion baselineCommit requirements source evidence rows')
    require(type(manifest['schemaVersion']) is int and manifest['schemaVersion'] == 1)
    require(isinstance(manifest['baselineCommit'], str) and re.fullmatch('[0-9a-f]{40}', manifest['baselineCommit']))
    ids = requirements(reference(root, manifest['requirements']))
    expected = {(req, platform) for req in ids for platform in PLATFORMS}
    expected.update((gate, 'all') for gate in GATES)
    frozen = manifest['source']
    fields(frozen, 'files sha256')
    require(isinstance(frozen['files'], dict) and 0 < len(frozen['files']) <= 20000)
    for name, value in frozen['files'].items():
        require(source_path(name) and isinstance(value, str) and SHA.fullmatch(value))
    require(frozen['sha256'] == sha(canonical(frozen['files'])))
    current = source_snapshot(root)
    source_matches = current == frozen
    evidence = manifest['evidence']
    require(isinstance(evidence, dict) and 0 < len(evidence) <= 1000)
    for key, item in evidence.items():
        token(key); fields(item, 'path sha256 kind')
        require(item['kind'] in ('report', 'acceptance'))
        reference(root, {k: item[k] for k in ('path', 'sha256')})
    rows = manifest['rows']
    require(isinstance(rows, list) and len(rows) == len(expected))
    seen, blockers = set(), []
    verification_counts = Counter({state: 0 for state in VERIFICATION})
    implementation_counts = Counter({state: 0 for state in IMPLEMENTATION})
    for row in rows:
        fields(row, 'requirement platform implementation verification evidence acceptance nextAction')
        identity = (row['requirement'], row['platform'])
        require(identity in expected and identity not in seen)
        seen.add(identity)
        require(row['implementation'] in IMPLEMENTATION and row['verification'] in VERIFICATION)
        token(row['nextAction'])
        refs = row['evidence']
        require(isinstance(refs, list) and 0 < len(refs) <= 20)
        require(all(isinstance(ref, str) and ref in evidence for ref in refs) and len(set(refs)) == len(refs))
        verification_counts[row['verification']] += 1
        implementation_counts[row['implementation']] += 1
        if row['verification'] == 'passed':
            require(row['implementation'] == 'implemented' and row['acceptance'] in refs)
            acceptance(root, evidence, row['acceptance'], row, frozen['sha256'],
                       manifest['requirements']['sha256'])
        else:
            require(row['acceptance'] is None)
        if row['verification'] != 'passed' or not source_matches:
            blockers.append(dict(requirement=identity[0], platform=identity[1],
                implementation=row['implementation'], verification=row['verification'],
                reason='source_changed' if not source_matches else row['verification'],
                nextAction=row['nextAction'], evidence=refs))
    require(seen == expected)
    return dict(schemaVersion=1, baselineCommit=manifest['baselineCommit'],
        sourceHash=frozen['sha256'], currentSourceHash=current['sha256'], sourceMatches=source_matches,
        requirementGroups=len(ids), rowCount=len(rows), verificationCounts=dict(verification_counts),
        implementationCounts=dict(implementation_counts),
        currentPasses=verification_counts['passed'] if source_matches else 0,
        releaseReady=not blockers, blockers=blockers)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--manifest', default='tool/release_readiness/inventory.json')
    parser.add_argument('--require-ready', action='store_true')
    args = parser.parse_args()
    try:
        root = args.root.resolve(strict=True)
        report = check(root, read_json(root, args.manifest))
        print(json.dumps(report, sort_keys=True, indent=2, allow_nan=False))
        return 1 if args.require_ready and not report['releaseReady'] else 0
    except (OSError, ValueError, TypeError, KeyError, RecursionError, subprocess.SubprocessError):
        print('Invalid release inventory; check coverage, identities and evidence.', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
