from pathlib import Path
import hashlib,json,subprocess
root=Path('/Users/yy2021_8689/.codex/worktrees/remaining-local-acceptance/yl_player');out=Path('/private/tmp/yl-local-acceptance')
changed=subprocess.check_output(['git','diff','--name-only'],cwd=root,text=True).splitlines()
new=subprocess.check_output(['git','ls-files','--others','--exclude-standard'],cwd=root,text=True).splitlines()
files={p:hashlib.sha256((root/p).read_bytes()).hexdigest() for p in sorted(set(changed+new)) if not p.startswith('docs/superpowers/reports/evidence/') and (root/p).is_file()}
v=dict(base=subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),branch=subprocess.check_output(['git','branch','--show-current'],cwd=root,text=True).strip(),trackedDiffSha256=hashlib.sha256(subprocess.check_output(['git','diff','--binary'],cwd=root)).hexdigest(),files=files,releaseScopeSha256=json.loads((root/'tool/release_readiness/inventory.json').read_text())['source']['sha256'],note='Uncommitted candidate file identities; excludes evidence directory to avoid a self-referential hash. Product scope is separate from CI/test/report scope.')
(out/'candidate-snapshot.json').write_text(json.dumps(v,indent=2)+'\n');print(len(files),'candidate files')
