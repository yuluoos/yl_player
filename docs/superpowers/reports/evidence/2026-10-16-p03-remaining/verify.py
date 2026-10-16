"""Replay retained raw observations; never promote a cached acceptance flag."""
from pathlib import Path
import gzip
import hashlib
import json
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[4]
sys.path.insert(0, str(ROOT / 'tool/media_matrix'))
from bound_matrix import summarize
from run_bound_flutter_apple import acceptance


def read(path):
    data = path.read_bytes()
    return json.loads(gzip.decompress(data) if path.suffix == '.gz' else data)


def main():
    manifest = read(HERE / 'manifest.json')
    for relative, expected in manifest.items():
        assert hashlib.sha256((HERE / relative).read_bytes()).hexdigest() == expected, relative
    results = {}
    for folder in sorted(HERE.glob('macos-matrix*')):
        plan = read(folder / 'matrix-plan.json')
        replay = summarize(plan, read(folder / 'records.json.gz'))
        assert replay == read(folder / 'matrix-result.json'), folder.name
        assert replay['attemptedRows'] == 44 and replay['requiredRows'] == 40
        assert not replay['fullAcceptance']
        results[folder.name] = replay['supportedRows']
    for folder in sorted(HERE.glob('macos-*')):
        if not (folder / 'rows.json.gz').is_file():
            continue
        result = acceptance(read(folder / 'plan.json'), read(folder / 'rows.json.gz'),
                            read(folder / 'status.json'), True)
        cached = read(folder / 'result.json')
        assert result['scopeAcceptance'] == cached['scopeAcceptance'], folder.name
        if 'negative' in folder.name:
            assert not result['scopeAcceptance']
        if 'negative-framework' in folder.name:
            assert result['supportedRows'] == 1 and not result['publicTestPassed']
        if 'negative-identity' in folder.name:
            assert result['supportedRows'] == 0 and not result['runtimeIdentityVerified']
        results[folder.name] = result['scopeAcceptance']
    print(json.dumps({'archiveVerified': True, 'rawReplay': results}, indent=2))


if __name__ == '__main__':
    main()
