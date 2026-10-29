from pathlib import Path
import json,hashlib,subprocess,sys
raw=Path('/private/tmp/yl-public-transport');sha=lambda b:hashlib.sha256(b).hexdigest()
for name in ['export-history.py','archive.py','verify-archive.py','readiness.py']:
 s=Path('/private/tmp/yl-public-race',name).read_text().replace('/private/tmp/yl-public-race','/private/tmp/yl-public-transport').replace('evidence/2026-10-28-ios-public-race','evidence/2026-10-28-ios-public-transport')
 if name=='export-history.py':s=s.replace('2026-10-28-ios-public-policy','2026-10-28-ios-public-race')
 if name=='verify-archive.py':s=s.replace('0ba2a263:','73f50a0d:').replace('assert changes==[]',"assert len(changes)==2 and {Path(p).name for p in changes}=={'YlApplePlayerHost.swift','YlAppleSessionCoordinator.swift'}")
 if name=='archive.py':s=s.replace('准备期限原生与验证器红灯、尾帧漏检红灯、原配置后台中断原始失败均保留','意图版本原生红灯、PTS/版本重放验证器红灯、暂停/跳转未恢复高档的原始失败均保留')
 (raw/name).write_text(s)
(raw/'review-followup.txt').write_text('''定向复审 /root/public_policy_review：仅检查本轮两项 P2 修复。
seek 使用 itemTimeForDisplay，按实际发布缓冲区身份关联 PTS；缺失、陈旧、数量不符均拒绝。
UInt64 单调、跨版本窗口失效、票据/命令/主采样/策略采样版本绑定均已修复。
红绿反例覆盖；46 项验证器通过；未发现新的 P1/P2。
真实 PTS 设备采集与最终记录待核对。原媒体失败必须保留，EOF 不替代高档输出。
''')
report=Path('docs/superpowers/reports/2026-10-28-ios-public-transport.md')
report.write_text('''# iOS 公开暂停/跳转与同源候选的竞争验证

基线 `73f50a0d`，分支 `codex/abr-recovery`。继续已授权剩余项；[完整证据](evidence/2026-10-28-ios-public-transport/)保留原生/验证器红绿、失败采集与完整 xcresult。不发布。

## 实现与边界

生产层仅暴露 coordinator 既有 restorationIntentRevision 的 internal 只读值，并将 AVPlayer video-output 默认工厂贯通内部构造函数。默认输出和计数行为不变；未新增 Pigeon 接口、生产重试或自动安装恢复候选。

诊断 Sample/Ticket 绑定真实已接受意图版本。同 item 的公开 pause/seek 也会撤销旧授权，play 不得使旧票据复活；无效命令不递增。版本变化重建资格窗口，但同源尝试不退款。新增原生红灯先复现同 item forward seek 后旧票据仍获准，再修复授权绑定及两窗重建。

public-policy-race 新增公开暂停/恢复与跳转场景。真实候选 ready 后调用 host.pause 或 host.seekTo，不手动 invalidateIntent。暂停保持至少2秒，由独立任务显式 host.play；跳转前进1000ms。原准备2秒、票据5秒、双8秒窗、955000bit/s、最多2次、500/1000ms退避全部保持。public-host 诊断故意不安装后续候选，不能据此声称生产恢复已经实现。

## 复审修复

两处 P2 均以反例红灯保存并修复：原跳转检查只读取 player.currentTime，无法证明帧本身的展示时间；原日志只检查命令版本+1，允许主采样倒退、错绑票据及跨版本合格窗。

现在测试 AVPlayerItemVideoOutput 子类读取 itemTimeForDisplay，以实际发布 CVPixelBuffer 身份关联 framePresentationTimes；保留缓冲区引用防止身份重用，记录最多64个。只有实际发布的帧进入证据，缺失/陈旧/数量不符拒绝。播放器时钟仍用于进度观察，不能代替 PTS。无需给生产逐帧路径增加诊断附着数据。

版本重放要求 UInt64 单调，变更立即清除窗口与待发票据；事件 ticketIntentRevision 必须绑定 ticketReady 决策，命令前后版本必须与主采样和策略采样一致。定向复审确认两处修复闭合，未发现新增 P1/P2。

## 真机结果

设备与已授权开发签名沿用前轮。120秒素材、140秒原生观察和240秒外部采集上限不变；原 profile 和独立零延迟诊断 profile 均不改动。本轮使用零延迟 profile 激发候选竞争，不替代原配置验收。

复审前 pause/seek 两轮都完成到片尾，公开命令使原候选 cancelled/detached，同 session/item 保留，版本0→1，第二张自然票据仍耗用同源预算且未安装。两轮命令后均只有320宽输出，没有恢复640，因此整轮 passed=false。原失败未重写，不能引用旧播放器时钟作为跳转落点通过证据。

FINAL_MEDIA_PENDING

## 统一验收与发布台账

FINAL_TESTS_PENDING

最终生产源码 SOURCE_HASH_PENDING；台账绑定更新，102行状态维持，releaseReady=false。只记录本轮诊断进展，未将部分合约通过提升为能力或物理连续性验收。

保留未完成项：公开暂停/跳转后高档恢复完整验收、凭据竞争、原配置稳定安全自动恢复、替换新帧空档与物理音画/字幕、真实路由和前后台恢复、Dart链路、多设备/最低系统、DRM/Dolby授权等。旧终末停顿不恢复为待办。未合并、推送、打标签或发布。
''')
p=Path('tool/release_readiness/inventory.json');d=json.loads(p.read_text());sys.path.insert(0,'tool/release_readiness');import check
old=d['source'];d['source']=check.source_snapshot(Path.cwd())
(raw/'production-source-change.json').write_text(json.dumps(dict(baseline='73f50a0d',beforeHash=old['sha256'],afterHash=d['source']['sha256'],changedFiles=[n for n,h in d['source']['files'].items() if old['files'].get(n)!=h]),indent=2)+'\n')
s=report.read_text().replace('SOURCE_HASH_PENDING',d['source']['sha256']);report.write_text(s)
d['evidence']['ios-public-transport-20261028']={'path':str(report),'sha256':sha(report.read_bytes()),'kind':'diagnostic'}
# Match the existing evidence kind vocabulary and attach only to existing related rows.
d['evidence']['ios-public-transport-20261028']['kind']=d['evidence']['ios-public-race-20261028']['kind']
for row in d['rows']:
 if 'ios-public-race-20261028' in row['evidence']:row['evidence'].append('ios-public-transport-20261028')
 if row['platform']=='ios' and row['requirement']=='CAP-ABR':row['nextAction']='qualify-public-transport-high-output-credential-races-original-auto-recovery-frame-gap-and-physical-output'
p.write_text(json.dumps(d,ensure_ascii=False,indent=2)+'\n')
print(d['source']['sha256'])
