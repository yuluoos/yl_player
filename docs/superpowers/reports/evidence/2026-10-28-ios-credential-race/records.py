from pathlib import Path
import json,hashlib,sys
raw=Path('/private/tmp/yl-credential-race');sha=lambda b:hashlib.sha256(b).hexdigest()
for name in ['archive.py','verify-archive.py','export-history.py','readiness.py']:
 s=Path('/private/tmp/yl-public-transport',name).read_text().replace('/private/tmp/yl-public-transport','/private/tmp/yl-credential-race').replace('evidence/2026-10-28-ios-public-transport','evidence/2026-10-28-ios-credential-race')
 if name=='export-history.py':s=s.replace('2026-10-28-ios-public-race','2026-10-28-ios-public-transport')
 if name=='verify-archive.py':s=s.replace('73f50a0d:','7a089625:').replace("assert len(changes)==2 and {Path(p).name for p in changes}=={'YlApplePlayerHost.swift','YlAppleSessionCoordinator.swift'}","assert len(changes)==1 and Path(changes[0]).name=='YlHlsHeaderPolicy.swift'")
 if name=='archive.py':s=s.replace('意图版本原生红灯、PTS/版本重放验证器红灯、暂停/跳转未恢复高档的原始失败均保留','凭据上下文/票据红灯、同步安装竞争红灯、v2证据验证器红灯均保留')
 (raw/name).write_text(s)
(raw/'foreground-confirmation.json').write_text(json.dumps({'date':'2026-10-28','initialDeviceState':'disconnected','userReply':'已连接并解锁，继续真机测试','scope':'本轮原生合约，不是长素材ABR复测'},ensure_ascii=False,indent=2)+'\n')
(raw/'review.txt').write_text('''独立综合复审 /root/credential_review：1个P2，无P1。
最后一次凭据版本读取与replaceActiveDash的实际item安装之间存在TOCTOU，后台strip可能穿过。
本地MP4 readiness+真实DASH redirect组合不等于同一个DASH候选的inflight网络取消或完整public/Dart/Load隔离。
本轮已实现同锁同步提交，并保存fence-red/fence-green，定向复核待完成；不提升完整恢复验收。
''')
report=Path('docs/superpowers/reports/2026-10-28-ios-credential-race.md')
report.write_text('''# iOS 诊断恢复候选凭据竞争与提交边界

基线 `7a089625`，本地分支 `codex/abr-recovery`。继续已授权剩余项，采用系统排障/TDD/集中验收。[完整证据](evidence/2026-10-28-ios-credential-race/)保存原始红绿、源码绑定与完整xcresult。不发布。

## 已确认问题与修复

诊断恢复原先直接构造YlPreparedHlsAsset，未传当前播放loader的凭据上下文；候选即使预先准备成功，也可能在旧代理经历跨源剥离后重新向原始资源发送测试凭据。票据同时只绑定item代次与transport revision，凭据状态变化不能直接撤销旧票据。该问题存在于诊断候选路径，不声称生产公开命令存在同样泄漏。

先抽取原逻辑，再用两个原生测试复现：候选上下文身份不相同，代理再次带回已剥离的凭据；凭据版本改变后旧票据仍获准，资格窗口未正确重建。完整red bundle保留两项失败（含所有断言），不能只用编译失败作为复现。

修复让候选沿用当前loader的YlHlsCredentialContext及source请求元数据；Sample/Ticket绑定credentialRevision。revision为该用户Load上下文永久剥离的不同资源数，重复strip不增长，锁保护并发读取与插入。凭据版本变化清除pending/inflight和窗口，但不退还源预算，也不复活旧票据。生产未添加自动恢复策略或安装入口。

采样版本2同时重放transport与credential revision：UInt64、单调、跨版本窗口重新计时、票据事件与发票决策双版本绑定。v2 installed事件还要求credentialCommitAccepted=true。缺字段、倒退、错绑、跨版本窗口和无提交锁证据均拒绝；版本1历史结果可识别但不提升覆盖。诊断只记录数字版本，不记录真实凭据内容；测试使用固定合成凭据。

## 独立复审与提交锁

综合复审发现1个P2：最终authorizes读取revision与实际replaceActiveDash之间仍有后台strip竞争。新增并发红灯在安装闭包内观察到strip提前完成；修复后withUnchangedRevision在同一上下文锁中比较版本并执行短同步提交。版本先变化则拒绝，提交先获锁则完成实际item安装后才允许strip。抛错也释放锁。

该同步闭包仅由受控诊断调用，当前和候选DASH已完成preflight；不做网络等待或上下文重入，回调仅保存诊断状态。现有已加载DASH资源/代理回调取得context锁时不持有安装要取得的资源锁。新增测试在真正backend的makePlayerItem处注入后台strip，验证其不能穿过实际换item。生产上下文新增只读版本和内部同步提交函数，其余生产源码不变。

REVIEW_PENDING

## 测试范围与限制

本地组合测试先让真实AVPlayer加载本地MP4到ready，再从独立DASH代理发出实际跨源redirect/return请求；共享上下文变化使准备取消、detach、无候选item返回、源预算仍为1。取消回调直接discard一个DASH准备候选，并验证其takeLoader被拒绝、proxy cancelled=1。另一个提前准备的共享上下文候选代理再次请求同资源，不再发送Authorization/Cookie/显式credential，普通header保留。独立上下文和并发重复strip也有覆盖。

上述测试使用合成带宽发出票据；不冒充真实DASH候选inflight网络请求被撤销、公开Load生命周期或完整public/Dart凭据竞争。当前证明范围是本地组合准备取消、共享代理的凭据继承，以及另一个直接backend测试覆盖的原子item提交。

FINAL_TESTS_PENDING

准备2秒、票据5秒、双8秒窗口、955000bit/s、最多2次、500/1000ms退避均未改变。本轮不重复长素材；上轮pause/seek两轮到EOF但仅320宽、高档恢复失败，完整保留在既有证据中，没有用本轮合约通过替代。

## 发布台账与剩余项

SOURCE_PENDING

台账只补充本轮诊断证据与后续行动，102行implementation/verification/acceptance状态维持；releaseReady=false。仍保留完整public/Dart凭据竞争、公开Load隔离、同一DASH候选inflight网络取消、原配置稳定自动恢复、暂停/跳转后640高档恢复、替换新帧空档与物理音画/字幕、多设备/最低系统和DRM/Dolby授权等未完成项。旧终末停顿不恢复待办。未合并、推送、打标签或发布。
''')
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());sys.path.insert(0,'tool/release_readiness');import check
before=d['source'];d['source']=check.source_snapshot(Path.cwd());(raw/'source-change.json').write_text(json.dumps(dict(baseline='7a089625',beforeHash=before['sha256'],afterHash=d['source']['sha256'],changedFiles=[n for n,h in d['source']['files'].items() if before['files'].get(n)!=h]),indent=2)+'\n')
report.write_text(report.read_text().replace('SOURCE_PENDING','最终生产源码哈希 '+d['source']['sha256']+'；源码绑定已更新。'))
d['evidence']['ios-credential-race-20261028']={'kind':d['evidence']['ios-public-transport-20261028']['kind'],'path':str(report),'sha256':sha(report.read_bytes())}
for row in d['rows']:
 if 'ios-public-transport-20261028' in row['evidence']:row['evidence'].append('ios-credential-race-20261028')
 if row['platform']=='ios' and row['requirement']=='CAP-ABR':row['nextAction']='qualify-public-credential-lifecycle-and-network-cancellation-high-output-original-auto-recovery-and-physical-output'
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n');print(d['source']['sha256'])
