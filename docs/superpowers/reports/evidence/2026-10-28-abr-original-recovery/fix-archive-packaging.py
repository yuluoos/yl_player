from pathlib import Path
import gzip,hashlib,json,subprocess
r=Path('/private/tmp/yl-abr-original-recovery');base=Path('docs/superpowers/reports/evidence/2026-10-28-abr-original-recovery')
for p in base.rglob('StandardOutputAndStandardError.txt'):
 data=p.read_bytes();assert data==(r/p.relative_to(base)).read_bytes()
 q=Path(str(p)+'.gz');q.write_bytes(gzip.compress(data,mtime=0));assert gzip.decompress(q.read_bytes())==data;p.unlink()
p=Path('docs/superpowers/reports/2026-10-28-abr-original-recovery.md');s=p.read_text();s+='\n最终纳入新文件后的差异检查发现原生原始stdout含CRLF/尾空格；保留失败检查记录，将该原始文本改为gzip存储并逐字节核验解压内容一致，没有清理或改写原日志，也没有忽略差异检查规则。修正后对整轮基线差异重新核对。\n';p.write_text(s)
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());d['evidence']['abr-original-recovery-20261028']['sha256']=hashlib.sha256(s.encode()).hexdigest();p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
for name,cmd,expected in [('ledger',['python3','-B','tool/release_readiness/check.py'],0),('required',['python3','-B','tool/release_readiness/check.py','--require-ready'],1)]:
 p=subprocess.run(cmd,capture_output=True,text=True)
 (r/('packaging-'+name+'.stdout')).write_text(p.stdout);(r/('packaging-'+name+'.stderr')).write_text(p.stderr);assert p.returncode==expected
print('raw bytes preserved and ledger rebound')
