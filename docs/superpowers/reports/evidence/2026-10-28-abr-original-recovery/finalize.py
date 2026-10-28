from pathlib import Path
import json,hashlib,subprocess
r=Path('/private/tmp/yl-abr-original-recovery')
p=Path('docs/superpowers/reports/2026-10-28-abr-original-recovery.md');s=p.read_text().replace('发布台账与性能阈值结构检查、15项台账回归及独立复审在最终归档中记录；完成后再核对报告哈希。','发布台账与性能阈值结构检查通过，15项台账回归通过；两个 `--require-ready` 均仍退出1。独立综合复审未发现P1/P2，已独立核对原始失败、两轮媒体、同源码复用、102行状态及完整归档，记录在 `independent-review.txt`。初次辅助分析因旧记录缺少signals文件失败，脚本与日志保留；修正为历史信号未知后重算通过，没有将缺文件推断为空信号。最终刷新报告哈希后再次核对台账。')
s+='\nCAP-ABR/iOS直接证据引用已达20项上限，本轮以新报告替换最近的直接引用；上一轮Dart证据总表项、报告与本报告链路均保留，没有删除历史验收记录。\n';p.write_text(s)
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());report=Path('docs/superpowers/reports/2026-10-28-abr-original-recovery.md');d['evidence']['abr-original-recovery-20261028']['sha256']=hashlib.sha256(report.read_bytes()).hexdigest();p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
p=Path('docs/superpowers/plans/2026-10-28-abr-original-recovery.md');s=p.read_text().replace('- [ ] 必要修改','- [x] 必要修改');s+='\n收尾：本轮两项真机诊断通过，原始网络失败两项保留；124项网络、15项台账回归通过，独立复审无P1/P2。生产自动恢复与连续性等未完成项仍保留，不能标记整体能力验收完成。\n';p.write_text(s)
results=[]
for name,cmd,wanted in [('ledger',['python3','-B','tool/release_readiness/check.py'],0),('required',['python3','-B','tool/release_readiness/check.py','--require-ready'],1),('diff',['git','diff','--check'],0)]:
 proc=subprocess.run(cmd,capture_output=True,text=True)
 for ext,data in [('stdout',proc.stdout),('stderr',proc.stderr)]: (r/('final-'+name+'.'+ext)).write_text(data)
 results.append(dict(name=name,command=cmd,exitCode=proc.returncode));assert proc.returncode==wanted
(r/'final-checks.json').write_text(json.dumps(results,indent=2)+'\n')
print('final report hash and ledger checked')
