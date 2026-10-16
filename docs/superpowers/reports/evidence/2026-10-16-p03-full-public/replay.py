"""Run from repository root, optionally passing an evidence directory."""
import gzip,hashlib,json,sys
from pathlib import Path
sys.path.insert(0,str(Path.cwd()/'tool/media_matrix'))
from bound_matrix import summarize
from bound_av import validate
root=Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).parent
output={}
for name in ('android-matrix-complete','macos-matrix-final','ios-matrix-final'):
    folder=root/name
    matrix=json.loads((folder/'matrix-plan.json').read_text())
    records=json.loads(gzip.decompress((folder/'records.json.gz').read_bytes()))
    actual=summarize(matrix,records)
    assert actual==json.loads((folder/'matrix-result.json').read_text()),name
    assert actual['attemptedRows']==44 and actual['requiredRows']==40 and not actual['missing']
    assert actual['fullAcceptance'] is False
    output[name]={k:actual[k] for k in ('supportedRows','requiredRows','formatScopeAcceptance','fullAcceptance','buildSha256')}
for platform,suffix in [('android','complete'),('macos','final')]:
    for negative in ('framework','identity'):
        folder=root/f'{platform}-negative-{negative}-{suffix}'
        plan=json.loads((folder/'plan.json').read_text())
        rows=json.loads(gzip.decompress((folder/'rows.json.gz').read_bytes()))
        result=json.loads((folder/'result.json').read_text())
        assert not result['scopeAcceptance'] and not result['publicTestPassed']
        raw=validate(plan,rows)
        if negative=='framework':assert raw['scopeAcceptance'] and raw['supportedRows']==6,(folder,raw)
        else:assert not rows and not result['runtimeIdentityVerified'],folder
        output[folder.name]=dict(rawSupported=raw['supportedRows'],accepted=result['scopeAcceptance'])
folder=root/'ios-negative-identity-final'
rows=json.loads(gzip.decompress((folder/'rows.json.gz').read_bytes()))
result=json.loads((folder/'result.json').read_text())
assert not rows and not result['runtimeIdentityVerified'] and not result['scopeAcceptance']
output[folder.name]=dict(rawSupported=0,accepted=False)
manifest=root/'manifest.json' 
if manifest.is_file():
    hashes=json.loads(manifest.read_text())
    files={str(p.relative_to(root)) for p in root.rglob('*') if p.is_file() and p!=manifest}
    assert files==set(hashes),'unlisted or missing evidence'
    for path,digest in hashes.items():assert hashlib.sha256((root/path).read_bytes()).hexdigest()==digest,path
    output['verifiedArchiveFiles']=len(hashes)
print(json.dumps(output,indent=2))
