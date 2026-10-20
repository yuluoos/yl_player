from pathlib import Path
import subprocess, hashlib,json
root=Path.cwd();main='8614375448fce17b5f6872903218c99e90f5b03b';branch='a057886188cca41fc83b4ca496c266c827cf8d33';base='ab73405190a1996f8d081236d7bb48865c47dbdc'
def git(*args):return subprocess.check_output(['git',*args],cwd=root)
def names(*args):return [x for x in git(*args).decode().split('\n') if x]
def unchanged(ref,paths):
    assert git('diff',ref,'--',*paths)==b''
unchanged(main,['packages','pubspec.yaml','pubspec.lock','docs/platform-support.md'])
p08=names('diff','--name-only',base,main)
exceptions=['docs/superpowers/plans/2026-09-26-remaining-overview.md','tool/release_readiness/inventory.json']
unchanged(main,[p for p in p08 if p not in exceptions])
p07=names('diff','--name-only',base,branch)
unchanged(branch,[p for p in p07 if p not in exceptions])
before=json.loads(git('show',main+':tool/release_readiness/inventory.json'))
after=json.loads((root/'tool/release_readiness/inventory.json').read_text())
before['evidence']['p07']['sha256']=after['evidence']['p07']['sha256']
assert before==after
archive=[]
for folder,ref,relative in [('2026-10-20-p07-public-resources',branch,True),('2026-10-20-p07-reference-comparison',branch,False)]:
    path=Path('docs/superpowers/reports/evidence')/folder
    lines=(root/path/'SHA256SUMS').read_text().splitlines()
    for line in lines:
        digest,name=line.split('  ',1)
        file=(path/name).as_posix() if relative else name
        assert hashlib.sha256(git('show',ref+':'+file)).hexdigest()==digest,file
    archive.append({'manifest':str(path/'SHA256SUMS'),'original_revision':ref,'entries_verified':len(lines)})
result={'main_before':main,'p07_head':branch,'base':base,'product_packages_and_locks_byte_identical_to_main':True,'platform_support_byte_identical_to_main':True,'p08_changed_paths':len(p08),'p08_all_other_paths_identical':True,'p07_changed_paths':len(p07),'p07_all_other_paths_identical':True,'conflict':'overview retained both append-only histories','inventory_change':'only evidence.p07.sha256; rows/source/statuses unchanged','historical_manifests_verified_at_original_revision':archive}
Path('/private/tmp/p07-main-merge-20261020/preservation.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result,indent=2))
