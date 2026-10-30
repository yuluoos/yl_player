from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-cancel-settlement');a=json.loads((r/'analysis.json').read_text());q=a['results'];assert len(q)==3
p=Path('docs/superpowers/reports/2026-10-29-ios-cancel-settlement.md')
s='''# iOS 取消任务收尾修复与恢复重复验证

基线92dec97f，承接[再次降档对照](2026-10-29-ios-recovery-cause.md)。用户继续授权实现未完成项、准备后约9分钟前台采集；沿用系统排障、TDD和集中验收。保留原失败及设备/授权缺口，不放宽门槛，不发布。

## 已确认的缺陷与修复

YlHlsMediaProxy.close/cancelAll先移除TaskRecord并立即封存诊断trace。之后URLSession didFinishCollecting/didComplete通过TaskRecord查找，取消任务的真实晚到指标因此丢失。修改现有真实响应前取消用例，原代码因缺任务完成时间/取消分类/下游关闭时间/metrics失败；红xcresult和日志保留。修改后定向4项通过。

修复仅在DEBUG诊断路径：独立diagnosticTaskTraces保持任务到didComplete；播放侧关闭依然立即取消，不等待日志。trace.finish冻结body/send字段及下游outcome，metrics可继续接收；等Foundation完成回调与下游完成都发生后封存，再在锁外交付observer。capture的pending仍在observer返回后才释放。active trace保留已关闭连接对象直到交付，防止ObjectIdentifier被新连接复用而清理错条目。不保留TaskRecord、请求头或凭据，不改变恢复策略/预算/网络重试。

v4区分downstreamTerminal、taskComplete、taskOutcome（0成功/1取消/2其他错误）及最终日志terminal；任务回调稍晚不等于播放停顿。旧v1–3含义保持。成功请求仍要求任务成功、所有事务核心时长完整及服务器关联；取消指标缺失不补0、不丢记录、不豁免无服务器关联。字段只包含有界分类和同设备时钟，不新增地址/URL/凭据。

独立复审发现一个P2：初版v4允许冻结时间之后仍有body/send事件。两项红例复现后，全部运输事件必须<=downstreamTerminal；成功记录另需taskComplete<=downstreamTerminal，取消仍允许任务稍晚完成。定向复审关闭P2，无新增P1/P2。

## 统一原生与工具验收

工具188/188通过；消费者46项中45通过、1项既有历史focused证据缺失跳过，三份原生测试镜像及历史来源一致。规范源码身份总数仍iOS876/macOS920，非本轮执行数量。

最终新制品iPhone相关原生249/249通过。macOS首次完整矩阵222/224：testProxyRequestTimingCorrelatesOwnedServerWithoutResourceIdentity在NWConnection ready的原2秒门槛超时，随后取消回调的断言在testProxyRequestTimingRecordsRealCancellationBeforeUpstreamResponse期间报告。发生在客户端就绪/请求接入前，具体触发因素尚未确定，不能据此认定诊断实现根因或已经修复。未改Swift源码与超时门槛，两项定向复核2/2通过、完整复测224/224通过；全部失败和复测xcresult保留。iOS devicectl诊断采集不完整警告和编译/运行警告也保留，不宣称零警告。

438份源码/测试/工具输入最终冻结，采集前后相同。重新构建后的307份iPhone制品指纹三轮一致。249/224按规范所选类的唯一用例身份绑定当前源码，本轮真实执行，不复用上一轮矩阵。Swift诊断修复后的绿4项之后补了连接身份保留，该最终变更由249/224矩阵覆盖。Dart/Android生产未改，本轮未重跑其全矩阵。

## 三轮真机结果

normal/normal-repeat保持repeat-stall-budget-diagnostic-v1，120秒素材、close模式：0秒500000B/s+40ms、10秒停流、15秒2000000B/s+0ms、60–65秒第二次停流、之后2000000B/s+0ms。均无公开暂停，保留两次预算用于两次真实安装。

original使用原封不动的down-and-recover-v1：0秒500000B/s+40ms，10秒50000B/s+200ms，25秒恢复500000B/s+40ms。原配置不要求人为触发安装，但原最终高档、EOF和严格证据门槛继续适用。955000bps、双8秒/每窗口3请求、缓冲5秒/剩余20秒、每源预算2、500/1000ms退避、准备2秒及票据5秒全部未变。

| 场景 | 安装数 | 第二次安装后高档秒 | EOF位置秒/宽度 | item边界新帧间隔ms | 全程最大新帧间隔ms | 严格回执 |
| --- | --- | --- | --- | --- | --- | --- |
'''
for n,v in q.items():
 f=v['final'];proof=v['secondInstallProof'];gaps='/'.join(f'{b["publicationGapMs"]:.3f}' for b in v['continuity']['replacementBoundaries']) or '无替换';tail=f'{proof["highTailSeconds"]:.3f}' if proof else '自然恢复';installs=sum(e['outcome']=='installed' for e in f['automaticEvents'])
 s+=f'| {n} | {installs} | {tail} | {f["position"]:.6f}/{f["width"]} | {gaps} | {v["continuity"]["maximumPublishedFrameGapMs"]:.3f} | '+('通过' if v['receiptPassed'] else '失败')+' |\n'
s+='''
严格回执及独立重算1/3通过，原生媒体探针3/3退出0并到EOF；无后台/音频切换信号或host failure。normal两次安装后，高→低→再次安装→新高帧顺序完整：第二次低68.996秒、安装86.584秒、新高86.711秒；normal-repeat分别69.076/86.578/86.718秒。两个高档尾部都保持640至EOF，只构成表列诊断条件下的重复输出证据，不覆盖严格关联失败。

original在24.150秒低档、39.980秒自然恢复高档，attempts/reservations/tickets均0；不能算自动恢复触发验收。原策略出现一个合格窗口，第二个窗口形成前已自然高档，取消恢复等待符合策略；本轮单样本自然恢复不能宣称原配置稳定性问题已解决。

发布层边界与全程最大间隔分别保留，所有轮次无纹理清空或无帧generation。没有修改替换算法，不将少量差异称为延迟优化。原配置最大1.352秒新帧间隔也保留。没有校准物理屏幕/声音测量，continuityAccepted、physicalOutputVerified、audioSynchronizationVerified、capabilityAccepted均false。

## 取消证据补齐与仍然失败的关联

三轮1162条proxy trace全部记录任务完成及非空metrics；其中取消记录14/14/6条均保留metrics。30个任务最终取消、4个任务最终成功但下游已取消，两个outcome独立保存。非空metrics不等于每个事务核心时长完整：三轮合计27条取消记录的核心区间仍不完整，成功请求无不完整区间，完整性检查没有放宽。下游关闭后到任务完成最大间隔分别1.240/0.840/2.134ms，是日志收尾量，不是画面指标。

normal/normal-repeat各有一个未关联的取消任务（proxy requestId 63/58）：从代理接入到下游关闭3.183/4.411ms，taskOutcome=1，一条事务、无重定向、无复用，只有fetch开始，requestStart及响应起止没有被Foundation记录，protocolCode=0；body/send计数为0。服务器生命周期分别412/408个接入全部对应解析请求，无接入拒绝或无请求连接，也没有这两个correlationID。原始字段支持“没有记录到HTTP请求开始/服务器对应请求”，不能进一步断言网络层从未发送字节或补造不存在的服务器请求。

因此fullyCorrelated=false、原回执passed=false，两个轮次保持失败。取消任务真实收尾缺失这个代码缺陷已修复，但快速取消的严格服务器关联缺口并未闭合。不得删除取消请求、改变分母或豁免无关联以让其通过。uncorrelated-cancellations.json完整保留两条新失败。

original的344条proxy全部关联346个服务器请求中的媒体请求；normal/normal-repeat分别411/407条proxy，有且只有上述一个未关联，服务器媒体请求均能找到代理记录。三轮没有双事务或不完整成功事务；本轮没有复现历史双事务，无法证明它的历史诱因已解决。v4带宽CLI三轮实际读取成功并保留partial状态，CLI退出0不是严格恢复通过。

## 归档、发布台账和未完成项

[完整证据](evidence/2026-10-29-ios-cancel-settlement/README.md)包含9个完整xcresult（红、绿、mac首轮失败/定向复核/完整复测、iPhone矩阵、三轮媒体）、所有原始收据/帧/策略/事务/服务器生命周期、命令、复审和源码/制品身份。历史35组8000条哈希逐项核对，旧失败原样保留。

生产源码指纹仅因DEBUG代理文件由62f46a45…变为5c828f44…；台账绑定新源码，102行implementation/verification/acceptance不提升，所有历史evidence保留。CAP-ABR/iOS最近引用更新并保持20直接引用限制。台账结构、15项回归、性能注册表和diff通过；sourceMatches=true、releaseReady=false，两个--require-ready仍预期退出1。不发布、不推送、不合并。

仍未完成：原配置/真实生产网络的重复稳定性、预算耗尽后的自然高档恢复机制；快速取消的严格服务器关联、历史双事务确切诱因；更多提交后故障/生命周期竞争、macOS本轮就绪超时的确切诱因；物理音画、更多设备/最低系统及授权媒体等缺口。已取消的旧终末停顿不恢复为待办。本轮完成DEBUG取消指标收尾修复和当前条件下验证，不提升整体ABR/连续性验收。
'''
p.write_text(s)
l=Path('tool/release_readiness/inventory.json');d=json.loads(l.read_text());key='ios-cancel-settlement-20261029';d['source']=json.loads((r/'production-source.json').read_text());d['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in d['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[e for e in row['evidence'] if e!='ios-recovery-cause-20261029']
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-fast-cancel-correlation-original-stability-historical-transactions-lifecycle-races-and-physical-av'
l.write_text(json.dumps(d,indent=2)+'\n')
plan=Path('docs/superpowers/plans/2026-10-29-cancel-settlement.md');plan.write_text(plan.read_text().replace('- [ ]','- [x]')+'\n本批实施及集中验收完成：工具188、消费者45通过1既有跳过、iPhone249/macOS最终224通过；mac首轮2失败保留。三轮严格1/3，两个再次恢复轮因快速取消关联仍失败；原配置单次自然恢复。34取消metrics全部保留，不代表所有事务完整或整体验收通过。详见本轮报告，不发布。\n')
