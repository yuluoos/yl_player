from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-server-timing');a=json.loads((r/'analysis.json').read_text());results=a['results'];p=Path('docs/superpowers/reports/2026-10-29-ios-server-timing.md')
text='''# iOS 服务器整形等待与写出成本对照

基线35819ab9，承接[连接持久性诊断](2026-10-29-ios-connection-persistence.md)。本轮补齐请求级服务器成本，修复已复现的整形排队超时/取消问题，完成三轮同制品真机诊断；生产播放器未改，不合并、不发布。

## 确认的修复与证据边界

旧Shaper.consume在获取共享锁时无限等待，等待期间不检查deadline或stop。真实线程持锁、60ms deadline/主动stop两种红测均失败，原始lock-red.log保留。改为最多50ms分段等待并检查请求状态；成功取得锁后仍在finally释放。保留按计划休眠扣减额度的规则，不把调度超时补成突发额度，不改变带宽、延迟、数据块或超时门槛。该修复经并发回归验证；本轮真机没有触发queueFailures，不能声称它修复了上一轮媒体超时。

每条请求新增同服务器单调时钟下的latency、queue、hold、sleep、headerWrite、bodyWrite次数、失败次数和耗时，以及计划休眠时长。sleep包含在hold中，不能重复相加；并发请求耗时总和不是整轮墙钟时间。write返回不证明客户端收到、解码或显示。原代理请求边界、URLSession事务、连接复用与完整关联门槛保持不变。

收尾校验将阶段与method、outcome、bodyBytesWritten、timelineState绑定；拒绝缺失/额外字段、阶段矛盾、未记录的成功写出/整形休眠、非法时长与次数、聚合溢出。独立复审的两类P2及sleep缺失残留均通过红绿回归关闭，保留review-red、review-sleep-red及最终日志。没有放宽成功事务或快速取消关联规则。

## 最终制品和统一验证

434份源码/工具输入冻结，采集前后指纹完全一致。307份原生制品哈希与上一轮一致；packages/yl_player_apple、packages/yl_player_media_core及example/ios相对制品源c7fad9c2未改。本轮复用制品，不冒充重新构建或执行整套macOS223/iPhone248原生合约。

服务器工具168项通过；消费者46项中45通过、1项既有历史focused证据缺失跳过；当前目标iOS875/macOS919清单和历史源码一致性检查通过。source-parity初次命令多传一个“--”导致CLI退出2，原始日志保留，纠正命令后退出0，未改变源码。台账15项回归、结构及性能注册表检查结果见归档。

用户确认约9分钟前台窗口。三轮同一down-and-recover-v1：初始500000B/s+40ms，10秒降至50000B/s+200ms，25秒恢复500000B/s+40ms；120秒素材，生产恢复开关开启，原策略双8秒合格窗口、955000bps等门槛不变。三轮无后台/音频切换信号、hostFailure=0，严格回执与XCTest均通过。

| 模式 | 结束位置秒 / 宽度 | 自然恢复后持续高档秒 | 自动尝试 | 请求 / 连接 / 复用请求 | 最大发布新帧空档ms |
| --- | --- | --- | --- | --- | --- |
'''
for name,q in results.items():
 c=q['connectionObservation'];text+=f"| {name} | {q['position']:.6f} / {q['finalWidth']} | {q['highTailSeconds']:.3f} | {q['attempts']} | {c['requests']} / {c['connectionsWithRequests']} / {c['reusedRequests']} | {q['continuity']['maximumPublishedFrameGapMs']:.3f} |\n"
text+='''
三轮均只有一次firstQualifiedWindow，随后自然恢复高档，未满足持续低档下的第二个合格窗口，因此automaticAttempts=0并非本轮可确认的调度遗漏。对应合格窗口带宽依次约1.157、1.226、1.088Mbps；只能说明这三次原配置观测已经足够完成第一个窗口，不能覆盖历史带宽不足/不升档失败。未预约或替换，故不能作为自动替换、退避预算、取消竞争的新增真机通过证据。物理输出、音画同步与整体连续性均仍false。

上一轮http11-close的原始CoreMedia超时、未EOF和尾部无新帧记录完整保留；本轮未复现，不将其标为修复，也不恢复已取消的旧终末停顿待办。三轮代理各344条均完整关联；取消请求仍保留，不以本轮完整关联覆盖历史快速取消未关联缺口。

## 请求级成本

以下仅统计服务器25秒后完整落在恢复阶段、代理成功并关联的请求；失败/取消/跨边界请求仍保存在原始日志及analysis.json的失败和最慢请求列表中。所有时长为请求总和（秒），sleep为hold子区间。

| 模式 | 请求 / 字节 | 上游生命周期 | 服务器总时长 | 延迟 | 排队 | 持锁 | 计划休眠 / 实际休眠 | 头写出 / 正文写出 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
'''
for n,q in results.items():
 b=q['phaseRequestBoundaries'][2];t=b['serverTiming']['sums'];text+=f"| {n} | {b['requests']} / {b['sums']['bodyBytes']} | {b['sums']['upstreamSeconds']:.3f} | {t['totalSeconds']:.3f} | {t['latencySeconds']:.3f} | {t['queueSeconds']:.3f} | {t['holdSeconds']:.3f} | {t['sleepRequestedSeconds']:.3f} / {t['sleepSeconds']:.3f} | {t['headerWriteSeconds']:.3f} / {t['bodyWriteSeconds']:.3f} |\n"
text+='''
实际整形休眠超过计划约2.8–2.9秒，是本轮可观测的服务器时间成本；这包括sleep调用和返回调度，不是网络RTT。恢复阶段延迟约10.9秒、持锁约13.6秒，正文写出仅约0.50–0.53秒。不能据此把此前超时归因于写出，不能从播放器带宽估计中扣除这些耗时，不能在整形器中补偿成额外发送额度。服务器totalSeconds与原startMs/endMs区间边界略有差异，分别保留；未混用两台机器绝对时间。

两种HTTP/1.1模式共同的唯一成功asset/range/bytes请求为247对、5200287字节，均始于25秒后。关闭/复用的计划休眠均10.401秒，实际休眠13.279/13.167秒，排队2.255/2.634秒，正文写出0.521/0.520秒，上游生命周期38.790/37.588秒。关闭有247次连接指标共6.108秒；复用有23次连接指标共0.382秒、224次复用。实际减少建连，并未消除固定延迟、休眠或排队，单轮顺序运行和只选成功请求也不足以证明稳定性或因果。缺失事务值仍保留null，不能当作实测零。

## 台账与未完成项

完整命令、红绿/复审、原始回执/请求/策略/帧/访问日志/事务、完整xcresult及哈希见[原始证据](evidence/2026-10-29-ios-server-timing/README.md)。旧31组证据清单及文件逐项核对，原失败不改写。三轮诊断通过不等于CAP-ABR通过。

生产源码指纹保持83c8ad3fe1693f53b58ff238ccee7d24615eea80c80cc5f59b3f65595e8c7bb3。102行implementation/verification/acceptance不提升，原证据entry全部保留；CAP-ABR/iOS直接引用承接到本报告以满足20引用上限。sourceMatches=true、releaseReady=false；发布与性能--require-ready仍退出1。

仍需：原配置恢复和长素材高档的重复稳定性、上轮HTTP/1.1超时的可重复归因及真实服务器对照；能实际触发生产自动恢复的最终制品竞争/退避/连续性采集；历史快速取消缺少关联的修复与验证；更多设备/最低系统、物理画面与音画同步、授权媒体等原有资源缺口。本轮数据不支持增加新的生产恢复行为或通过调整整形速率/ABR门槛制造通过。
'''
p.write_text(text)
ledger=Path('tool/release_readiness/inventory.json');x=json.loads(ledger.read_text());key='ios-server-timing-20261029';x['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in x['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  if 'ios-connection-persistence-20261029' in row['evidence']:row['evidence'].remove('ios-connection-persistence-20261029')
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-original-recovery-reproducibility-http11-timeout-production-races-fast-cancel-and-physical-av'
ledger.write_text(json.dumps(x,indent=2)+'\n')
plan=Path('docs/superpowers/plans/2026-10-29-server-timing.md');plan.write_text(plan.read_text().replace('- [ ]','- [x]')+'\n本轮已实施并完成工具168/消费者45通过1既有跳过、三轮同制品真机诊断通过。全部自动尝试0，自然升档不代表自动恢复或连续性验收；失败与设备授权缺口保留，台账不提升、不发布。\n')
