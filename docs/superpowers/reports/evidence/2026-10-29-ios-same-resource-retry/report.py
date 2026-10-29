from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-same-resource-retry');a=json.loads((r/'analysis.json').read_text());q=a['results'];assert len(q)==4
rel=json.loads((r/'resource-relations.json').read_text());repro=json.loads((r/'reproduction-analysis.json').read_text());history=json.loads((r/'prior-evidence.json').read_text());source=json.loads((r/'production-source.json').read_text())
p=Path('docs/superpowers/reports/2026-10-29-ios-same-resource-retry.md')
s='''# iOS 同资源取消后请求合约与恢复重复采集

基线2f677eb4，承接[资源关联诊断](2026-10-29-ios-resource-correlation.md)。用户授权准备后约12分钟前台采集，沿用系统排障及集中验收。生产代码/策略与全部门槛不变，保留原失败和设备/授权缺口，不发布。

## 本轮完成的回归

扩展现有真实网络用例testQueuedProxyCancellationNeverReachesServerOrPoisonsNextRequest。测试设备回环服务器与真实URLSession占住一个上游连接名额，第二个完整GET+EOF造成快速取消；等待真实taskComplete后才释放首请求。释放后服务器仍仅有/held，不允许旧请求晚发；然后由测试调用方显式请求同一/cancelled URL，验证数据成功、taskOutcome=0、resourceToken相同但correlationID不同，服务器第二条记录仅对应新ID，原取消ID仍不存在。

原始附件同时保存trace和followupTrace。它证明同URL后续成功不会为旧取消请求建立服务器关联，不等于证明AVPlayer自动重试。测试仅把原来的/after换为同URL并增加身份与服务器证据断言，生产取消/恢复实现、v6诊断、Python关联门槛均未改。未发现新的生产行为缺陷，不虚构生产修复或红测。

| 执行 | 原取消生命周期ms | 显式同URL新请求距原取消ms | 原请求关联 | 后续任务结果 |
| --- | --- | --- | --- | --- |
'''
for n,v in repro.items():s+=f'| {n}/{v["device"]} | {v["cancelledLifetimeMs"]:.6f} | {v["explicitSameURLAdmissionAfterCancellationMs"]:.6f} | 仍缺失 | 成功 |\n'
s+='''
reproduction-analysis.json还用服务器真实解析顺序的本地序号适配旧取消记录的格式检查（这些不是服务器分配ID，也不是媒体回执）；原v6解析器仍返回fullyCorrelated=false及proxy request correlation incomplete。相同资源token不参与匹配。受控单名额、设备回环条件与Mac局域网长素材分开，不推断历史AVPlayer连接名额占用或内部取消原因。

## 统一验证

定向macOS1/1通过，完整iPhone251/251、macOS226/226通过，唯一用例身份与规范源码绑定。工具191/191，消费者46中45通过、1项既有历史focused证据缺失跳过。规范源码身份仍iOS878/macOS922，不当成本次执行量。438份输入、307份最终iPhone制品冻结，四轮前后指纹一致。生产源码指纹与基线相同；Dart/Android未改，本轮未重跑其全矩阵。编译/运行警告及诊断包保留，不宣称零警告。独立代码及最终综合复审无P1/P2，详见review-code.md、review-failure.md、review-final.md。

## 四轮真机长素材

normal/normal-repeat/normal-third均使用原repeat-stall-budget-diagnostic-v1：0秒500000B/s+40ms、10秒停流、15秒2000000B/s+0ms、60–65秒再次停流、之后2000000B/s+0ms。original保持down-and-recover-v1：0秒500000B/s+40ms、10秒50000B/s+200ms、25秒500000B/s+40ms。120秒自有素材，close模式。三轮诊断与原配置分开解释。

955000bps、双8秒/每窗口3请求、缓冲5秒/剩余20秒、每源2次预算、500/1000ms退避、准备2秒/票据5秒不变。成功请求全部事务核心区间必须完整，所有取消请求仍参与严格服务器关联；缺关联继续失败。

| 场景 | 真实安装数 | 第二次高档尾部秒 | EOF位置秒/宽度 | 替换新帧间隔ms | 全程最大新帧间隔ms | 严格回执 |
| --- | --- | --- | --- | --- | --- | --- |
'''
for n in ['normal','normal-repeat','original','normal-third']:
 v=q[n];f=v['final'];proof=v['secondInstallProof'];gaps='/'.join(f'{b["publicationGapMs"]:.3f}' for b in v['continuity']['replacementBoundaries']) or '无替换';tail=f'{proof["highTailSeconds"]:.3f}' if proof else '无第二次安装';installs=sum(e['outcome']=='installed' for e in f['automaticEvents'])
 s+=f'| {n} | {installs} | {tail} | {f["position"]:.6f}/{f["width"]} | {gaps} | {v["continuity"]["maximumPublishedFrameGapMs"]:.3f} | '+('通过' if v['receiptPassed'] else '失败')+' |\n'
s+=f'\n严格回执{a["strictPasses"]}/4，独立重算{a["reassessedPasses"]}/4。原生探针通过不能覆盖证据失败。\n'
for n,v in q.items():
 phases=' → '.join(f'{phase["elapsed"]:.3f}秒/{phase["width"]}宽' for phase in v['publishedPhases'])
 s+=f'\n- {n}：nativeExitCode={v["nativeExitCode"]}；{phases}；预约/票据={len(v["reservations"])}/{len(v["tickets"])}；严格错误='+json.dumps(v['receiptErrors'],ensure_ascii=False)+'。\n'
s+='''
二次恢复仍逐帧检查“首次安装后高档→再次低档→第二次安装后新generation高档”，不以attempts代替实际安装。原配置自然升档不计自动安装覆盖。采样新帧间隔不代表物理音画，continuityAccepted、physicalOutputVerified、audioSynchronizationVerified、capabilityAccepted继续false，未声称缩短空档。

## 取消与资源关系
'''
for n,v in q.items():
 d=rel[n];s+=f'\n{n}：proxy={v["proxyCount"]}，取消={len(d["cancellations"])}，未关联取消={len(d["uncorrelated"])}，服务器接入/解析={v["lifecycle"]["acceptedCount"]}/{v["lifecycle"]["parsedRequests"]}。\n'
 for b in d['uncorrelated']:
  s+=f'\n未关联requestID={b["requestID"]}，cause={b["cancelCause"]}，存活{b["downstreamLifetimeMs"]:.3f}ms；其他逐请求已关联记录中的同URL资源候选='+json.dumps(b['relatedServerAssetCandidates'])+'；其取消后成功完成的同URL请求='+json.dumps([dict(requestID=x['requestID'],afterCancellationMs=round(x['admissionRelativeToCancellationMs'],3),asset=x['asset']) for x in b['laterCompletedSameURLRequests']])+'。原请求serverRequestID仍为null，候选不构成原请求已到服务器的证据。\n'
total=sum(v['proxyCount'] for v in q.values());cancelled=sum(v['settlement']['cancelled'] for v in q.values());incomplete=sum(v['settlement']['incompleteMetrics'] for v in q.values());missing=sum(len(v['settlement']['metricsMissing']) for v in q.values());bad=sum(len(v['incompleteSuccessfulRequests']) for v in q.values());multi=sum(len(v['multipleTransactions']) for v in q.values());unlinked=sum(len(v['uncorrelated']) for v in rel.values())
s+=f'\n共{total}条proxy、{cancelled}条取消；非完整metrics={incomplete}、完全缺metrics={missing}、不完整成功事务={bad}、双事务记录={multi}。非空不等于完整。\n'
if not unlinked:s+='\n本轮未复现未关联快取消，不能据成功轮次关闭历史失败，也无法为旧无token记录追补资源身份。\n'
else:s+='\n本轮带token的未关联记录按原门槛失败保留。资源关系提供前后请求上下文，不证明AVPlayer取消决策或Foundation实际连接占用。\n'
s+='''
本轮normal还复现成功双事务缺区间：proxy C459CA68-0CFA-4FC2-BA04-9A3359F8E0F2/request4，第一事务requestStart/requestEnd存在，但responseStart/responseEnd缺失（responseWaitSeconds状态2、responseSeconds状态3、fetchSeconds状态2）；第二事务完整，redirectCount=0，两个reused=0，HTTP/1.1。服务器仅一条相同correlationID记录148，对应network-period-9/chunk-2-00002.m4s，写出8418字节成功。414次接入均已解析、无未解析连接，但缺少事务级跨端身份，不能判断第一事务到了哪一层、为何重建连接或是否为网络重试。不能将最终响应成功替代首事务区间完整性。

原始normal回执errors=[ValueError]，在成功请求全部事务必须完整的门槛处提前退出，故无continuityObservation等后续字段。独立重算保持原失败并从原始帧重建连续性；boundary-diagnosis.json逐条定位失败在proxy_boundaries.py的transaction_metrics.complete断言。另一独立缺口是request63未关联，不能因为前一检查提前退出而遗漏或按同URL回填。

normal的同代理request62为640宽高档分片，EOF取消后7.061ms接入相同resourceToken的request63；request63在4.253ms后EOF取消，11.535ms后接入逐请求已关联的低档init-0（request64）。request63没有后续成功的同URL请求，也没有自己的服务器记录；这些是同代理原始URL身份和时序证据，不证明method/range相同或AVPlayer内部重试/降档决策。该时段早于首次生产替换，不能归因于替换清理。保留两个新失败，不通过延迟取消、强迫无用请求接入服务器或放宽事务完整性来制造通过；当前无可确认且安全的生产行为修复。
'''
s+='''
normal-third再次复现高档分片request62取消后6.060ms出现同URL request63，后者5.693ms后EOF取消，仍无服务器关联。此外第二次安装附近（相邻采样86.966–87.224秒）旧代理request173/174/175记录cancelAll，分别存活13.933/4.555/4.240ms，均无服务器关联且无同代理同token候选；不能猜测其资源路径。早期下游EOF与后期cancelAll为两种记录来源，不能混为单一原因，全部保留在严格失败分母。

带宽诊断CLI原normal因相同完整事务断言退出1，其他三轮退出0；CLI退出0本身不表示严格回执通过（normal-third仍关联失败）。分析脚本对原始回执缺字段的兼容仅允许独立重算，不改回执。

resource-relations.json保留同代理、同原始URL标识的全部关联观察；failure-cause-analysis.json保留未关联任务的真实字段及并发寿命上下文。相同token不证明method/range/凭据版本/内容相同，其他请求成功不修复旧关联缺失。历史取消原因、ABR请求切换或连接名额的推测，均须与本轮直接观测区分。

## 归档与发布台账

[完整证据](evidence/2026-10-29-ios-same-resource-retry/README.md)包含7个完整xcresult（定向、两平台矩阵、四轮媒体）、导出原始同资源附件、原始帧/策略/事务/服务器记录、源码/制品身份及独立复审。失败和跳过原样保留。
'''
s+=f'\n历史{len(history)}组{sum(v["files"] for v in history)}条哈希与2f677eb4逐项一致。生产指纹仍为{source["sha256"]}，102行implementation/verification/acceptance不提升。旧全局evidence定义和报告链保留，CAP-ABR/iOS仍20个直接引用，最近引用轮替为本报告，开头链接上轮。\n'
s+='''
台账结构/15项回归/性能注册表/diff通过，sourceMatches=true、releaseReady=false；两个--require-ready仍因条件未满足退出1。不发布、不推送、不合并。

未完成：实际AVPlayer快取消的内部原因与严格关联、历史双事务诱因、真实网络/更多设备稳定性、预算耗尽后的自然高档、更多提交后故障及生命周期竞争、历史macOS就绪超时诱因；物理音画、更多设备/最低系统和授权媒体缺口。已取消的旧终末停顿不恢复为待办，不授予整体ABR/连续性验收。
'''
p.write_text(s)
l=Path('tool/release_readiness/inventory.json');d=json.loads(l.read_text());assert d['source']==source;key='ios-same-resource-retry-20261029';d['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in d['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[e for e in row['evidence'] if e!='ios-resource-correlation-20261029']
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-avplayer-same-resource-cancel-and-urlsession-missing-response-stability-and-physical-av'
l.write_text(json.dumps(d,indent=2)+'\n')
