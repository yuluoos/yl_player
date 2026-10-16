"""Replay the retained raw windows and identities; run from repository root.

Only the separately named source-pull proof may pass for AVPlayer. Never promote
it to played-sample, complete-format, release, or physical-output acceptance.
"""
import base64
import gzip
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path.cwd() / 'tool/media_matrix'))
from bound_artifacts import canonical
from bound_av import validate_render_pull
from run_bound_flutter_apple import acceptance

root = Path(__file__).parent
output = {}
for platform in ('macos', 'ios'):
    build = None
    for mode in ('positive', 'negative-framework', 'negative-identity'):
        folder = root / f'{platform}-final-{mode}'
        plan = json.loads((folder / 'plan.json').read_bytes())
        rows = json.loads(gzip.decompress((folder / 'rows.json.gz').read_bytes()))
        status = json.loads((folder / 'status.json').read_bytes())
        saved = json.loads((folder / 'result.json').read_bytes())
        product = json.loads((folder / 'product-files.json').read_bytes())
        raw_manifest = canonical(product['files'])
        assert base64.b64decode(product['manifest']) == raw_manifest
        assert hashlib.sha256(raw_manifest).hexdigest() == product['sha256']
        assert plan['productManifest'] == product['manifest']
        build = build or product['sha256']
        assert product['sha256'] == build
        assert json.loads((folder / 'launch.json').read_bytes())['preverified']
        # The deliberately wrong expected hash makes native identity/stability
        # fail, although the separately frozen bundle bytes remain unchanged.
        assert json.loads((root / 'post-run-product-verification.json').read_bytes())[platform]
        if mode != 'negative-identity':
            assert saved['artifactsUnchanged']
        actual = acceptance(plan, rows, status, True)
        assert all(actual[k] == saved[k] for k in actual), folder
        assert not actual['scopeAcceptance'] and not actual['fullAcceptance']
        if mode == 'negative-identity':
            assert not rows and not actual['runtimeIdentityVerified']
            assert not actual['publicTestPassed']
        else:
            assert plan['buildSha256'] == build
            raw = validate_render_pull(plan, rows)
            assert raw['renderPullAcceptance'] and raw['supportedRows'] == 1
            assert actual['runtimeIdentityVerified']
            assert actual['renderPullAcceptance'] == (mode == 'positive')
            assert actual['publicTestPassed'] == (mode == 'positive')
            assert actual['errors'] == ['played_sample_clock_unverified']
        output[folder.name] = {k: actual.get(k) for k in (
            'scopeAcceptance', 'renderPullAcceptance', 'publicTestPassed',
            'runtimeIdentityVerified')}
    if platform == 'macos':
        folder = root / 'macos-final-controls'
        plan = json.loads((folder / 'plan.json').read_bytes())
        rows = json.loads(gzip.decompress((folder / 'rows.json.gz').read_bytes()))
        status = json.loads((folder / 'status.json').read_bytes())
        saved = json.loads((folder / 'result.json').read_bytes())
        assert plan['buildSha256'] == build and saved['artifactsUnchanged']
        actual = acceptance(plan, rows, status, True)
        assert all(actual[k] == saved[k] for k in actual)
        assert actual['scopeAcceptance'] and actual['supportedRows'] == 6
        output[folder.name] = {'scopeAcceptance': True, 'supportedRows': 6}

manifest = root / 'manifest.json'
if manifest.exists():
    hashes = json.loads(manifest.read_bytes())
    files = {str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and p != manifest}
    assert files == set(hashes), 'unlisted or missing archive files'
    for name, digest in hashes.items():
        assert hashlib.sha256((root / name).read_bytes()).hexdigest() == digest, name
    output['verifiedArchiveFiles'] = len(hashes)
print(json.dumps(output, indent=2))
