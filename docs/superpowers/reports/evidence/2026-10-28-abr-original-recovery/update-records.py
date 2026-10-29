from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-abr-original-recovery');d=json.loads((r/'analysis.json').read_text());a=d['current']['original'];b=d['current']['zero-latency']
for x in [a,b]:
 assert x['receiptPassed'] and x['completed'] and x['position']>=119.5 and x['observation']['upshiftAfterDownshiftObserved'] and x['actualHighPublishedFrames']>0 and x['signals']==[]
assert b['highFramesAfterInstall']==[dict(attempt=1,frames=1984)]
assert a['tickets']==0 and b['tickets']==1 and len(b['events'])==1 and b['events'][0]['outcome']=='installed' and b['events'][0]['credentialCommitAccepted']
receipts=[json.loads((r/'network-restored-media'/n/'receipt.json').read_text()) for n in ['original','zero-latency']]
assert receipts[0]['binaryHashes']==receipts[1]['binaryHashes']
(r/'final-media-verification.json').write_text(json.dumps(dict(sameBinary=True,binaryFiles=len(receipts[0]['binaryHashes']),sourceFiles=d['sourceFilesUnchanged'],originalNaturalHigh=True,normalAutoInstalledHigh=True,productionAutoRecoveryAccepted=False,continuityAccepted=False),indent=2)+'\n')
results=f'''同一当前制品、同一120秒素材，正常后端诊断路径 `normal / auto-reload / manifest-only`；原生140秒、外部240秒、双8秒窗口、955000 bit/s、每窗口至少3请求及每源2次预算不变。原配置哈希 `4e4f256c59465f4a573d6ab1c48f7a7571294638025088d0cddba9325f5032ea`，既有独立零延迟配置哈希 `9f63acdf1ab0ce92c5565bc3a750478f0c6c5ba76cef88c7e1092cfcd89b01f1`。

| 本轮场景 | 实际结果 | 触发与高档 |
| --- | --- | --- |
| 原 down-and-recover-v1 | EOF {a['position']:.9f}秒，XCTest 1/1通过 | 0票据；640→320→640，自然恢复 |
| 零延迟正常自动替换对照 | EOF {b['position']:.9f}秒，XCTest 1/1通过 | 1票据、1次真实安装，替换后640 |

原配置在33.598003秒完成第一窗口：1149581.630 bit/s、23请求；41.144701秒已恢复640，早于第二窗口最早41.598003秒，策略清除观察窗口而不发票据。因此本轮“未触发”不是恢复缺陷，也不是自动替换覆盖。最终发布帧{a['continuity']['publishedFrames']}，实际640帧{a['actualHighPublishedFrames']}。

零延迟对照在28.630753/36.698770秒分别达到1748664.461/2734220.942 bit/s，20/18请求；36.698770秒预约、37.198770秒到期、37.222793秒发票据。事件记录真实item替换及凭据提交栅栏通过，38.146557秒恢复640。预算消耗1且未退款；此轮只覆盖第一次500ms退避，第二次1000ms与预算耗尽仍引用已有合约，不声称本轮真机覆盖。最终发布帧{b['continuity']['publishedFrames']}，实际640帧{b['actualHighPublishedFrames']}，其中安装后1984帧；安装后的首个640帧样本38.002298秒、最后一个120.623463秒。

两轮系统信号文件均为空，未记录前后台/音频切换；同制品哈希一致。替换边界的新帧空档138.402500ms、位置差31.483711ms、纹理清空0次；全程最大新帧空档分别{a['continuity']['maximumPublishedFrameGapMs']:.6f}/{b['continuity']['maximumPublishedFrameGapMs']:.6f}ms，不能把替换边界数值当成全程连续性。`physicalOutputVerified`、`audioSynchronizationVerified`、`continuityAccepted`、`capabilityAccepted`均仍false；不对AVPlayer内部penalty box决策作证明。'''
s=(r/'report-base.md').read_text().replace('RESULTS',results).replace('CHECKS','发布台账与性能阈值结构检查、15项台账回归及独立复审在最终归档中记录；完成后再核对报告哈希。')
p=Path('docs/superpowers/reports/2026-10-28-abr-original-recovery.md');p.write_text(s)
p=Path('tool/release_readiness/inventory.json');inventory=json.loads(p.read_text());key='abr-original-recovery-20261028';report=Path('docs/superpowers/reports/2026-10-28-abr-original-recovery.md');inventory['evidence'][key]=dict(kind='report',path=str(report),sha256=hashlib.sha256(report.read_bytes()).hexdigest())
for row in inventory['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[key if x=='dart-credential-race-20261028' else x for x in row['evidence']]
  row['nextAction']='qualify-production-auto-recovery-other-commit-failures-high-output-stability-and-physical-output'
p.write_text(json.dumps(inventory,ensure_ascii=False,indent=2)+'\n')
p=Path('docs/superpowers/plans/2026-10-28-abr-original-recovery.md');s=p.read_text();s=s.replace('- [ ] 核对','- [x] 核对').replace('- [ ] 同一','- [x] 同一').replace('- [ ] 结合','- [x] 结合');p.write_text(s+'\n本轮未发现需要改动生产恢复逻辑的可确认缺陷；原配置自然升档与正常自动替换均已完成真机对照。首请求网络拒绝两轮失败保留。最后统一验收记录见本轮报告。\n')
