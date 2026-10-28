from pathlib import Path
import json,hashlib,subprocess,shutil
raw=Path('/private/tmp/yl-public-transport');base=Path('docs/superpowers/reports/evidence/2026-10-28-ios-public-transport');sha=lambda b:hashlib.sha256(b).hexdigest()
review='''最终记录独立复核 /root/public_policy_review：通过。
iPhone205/205、macOS180/180通过；两轮EOF但仅320，passed=false，未升级验收。
seek1967帧PTS完整，最小38.041667秒符合目标38.057秒原50ms容差。
生产改动限定为只读版本暴露与默认工厂注入，22项源码绑定匹配。
102行状态未变，releaseReady=false；发布和性能require-ready均退出1。
归档时260项清单、10个完整xcresult、242项原始来源记录核对一致。
未完成项与失败边界准确；复核者未改文件或重跑测试。
本记录加入后重算归档清单，之前260为加入final-verification及本记录前的清单条目数。
'''
(raw/'final-review.txt').write_text(review)
report=Path('docs/superpowers/reports/2026-10-28-ios-public-transport.md');s=report.read_text();s+='\n最终记录独立复核通过。10份完整xcresult与原bundle逐文件哈希一致；历史16组、4291个清单文件未改写。归档保留242项原始来源记录以及后补的最终复核/门禁记录，详见raw-provenance与SHA256SUMS。\n';report.write_text(s)
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());d['evidence']['ios-public-transport-20261028']['sha256']=sha(report.read_bytes());p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
shutil.copyfile('docs/superpowers/plans/2026-10-28-ios-public-transport.md',raw/'final-plan.md')
results=[]
for name,cmd,expected in [('ledger',['python3','-B','tool/release_readiness/check.py'],0),('required',['python3','-B','tool/release_readiness/check.py','--require-ready'],1),('diff',['git','diff','--check'],0)]:
 r=subprocess.run(cmd,capture_output=True,text=True);assert r.returncode==expected,(name,r.stderr)
 results.append(dict(name=name,command=cmd,exitCode=r.returncode,stdout=r.stdout,stderr=r.stderr))
(raw/'final-record-checks.json').write_text(json.dumps(results,indent=2)+'\n')
records=json.loads((base/'raw-provenance.json').read_text())
for name in ['final-review.txt','final-plan.md','final-record-checks.json','seal-records.py']:
 src=raw/name;dest=base/name;dest.write_bytes(src.read_bytes());records.append(dict(source=name,sourceSha256=sha(src.read_bytes()),archive=name,archiveSha256=sha(dest.read_bytes())))
(base/'raw-provenance.json').write_text(json.dumps(records,indent=2)+'\n')
files=sorted(p for p in base.rglob('*') if p.is_file() and p.name!='SHA256SUMS');(base/'SHA256SUMS').write_text(''.join(sha(p.read_bytes())+'  '+str(p.relative_to(base))+'\n' for p in files))
print(dict(finalManifestEntries=len(files),rawProvenanceEntries=len(records)))
