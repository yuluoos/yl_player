from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-resource-correlation');a=json.loads((r/'analysis.json').read_text());q=a['results'];assert len(q)==4
relations=json.loads((r/'resource-relations.json').read_text());ca=json.loads((r/'cancellation-analysis.json').read_text())['results'];history=json.loads((r/'prior-evidence.json').read_text());source=json.loads((r/'production-source.json').read_text())
p=Path('docs/superpowers/reports/2026-10-29-ios-resource-correlation.md')
s='''# iOS 快速取消资源关系与恢复稳定性

基线9d43d6b4，承接[快速取消复现](2026-10-29-ios-queued-cancel.md)。用户授权构建后四轮约12分钟前台采集。继续系统排障、TDD与集中验收，保留失败和资源缺口，不放宽任何关联/恢复门槛，不发布。

## 本轮实现

原取消来源日志已能区分整体代理失效和下游EOF，但无法判断未关联请求是否后来对同一资源重试。本轮仅补DEBUG诊断：每个YlHlsMediaProxy创建独立随机256位SymmetricKey，用HMAC-SHA256处理现有destination.absoluteString，产生64位小写十六进制resourceToken。密钥不输出，不保留URL映射表，不新增请求头；关闭代理后不提供跨代理标识。仅显式诊断捕获下计算并记录，未改变取消、重试、恢复或播放决策。

同一代理内相同URL可比较，不同代理使用不同密钥；相同token不证明请求method/range/凭据版本或返回内容相同，也不能代替逐请求correlationID。HMAC标识不能用来查找没有对应请求的服务器记录。分析始终按(proxyID,resourceToken)分组，并保留serverRequestID=null及原失败。

实际代理trace及媒体探针升为v6，要求resourceToken存在且为64位小写hex；v1–5仍支持，并拒绝旧版携带该字段。现有直接构造的纯trace测试未提供资源时仍产生v5，实际代理捕获始终提供v6。metrics内部版本和全部完整性门槛未改。

新增原生真实网络测试：同一代理请求同一带测试凭据URL两次、不同URL一次、另一代理请求原URL一次。验证同代理相同URL标识稳定、不同URL区分、跨代理不相同，以及输出无URL/凭据原文。测试原实现因resourceToken缺失失败，红xcresult保留；修复后该项连同受控快速取消及正常关联共3项定向通过。Python新增反例证明同资源的成功请求不能补齐取消请求的服务器关联，缺失/非法字段均拒绝；真实CLI覆盖v6路径。

## 集中测试与制品

网络工具191/191通过；消费者46项中45通过、1项既有历史focused证据缺失跳过。iPhone相关原生251/251、macOS226/226通过，逐个唯一身份绑定规范测试。规范源身份计数iOS878/macOS922，不等于本轮执行数量。独立代码复审未发现P1/P2，核查密钥生命周期、隐私、兼容性和关联门槛。

438份源码/工具输入冻结，307份iPhone制品指纹四轮相同，前后核对。生产源码指纹只有DEBUG代理文件变化，Dart/Android无改动，本轮未重跑其全矩阵。Xcode/编译警告原样保留，不宣称零警告。新增诊断可能影响极短事件的运行时序，本轮采集绑定同一最终制品，不据不同批次的差异宣称性能修复。

## 四轮最终制品采集

原配置original/original-repeat保持down-and-recover-v1：0秒500000B/s+40ms、10秒50000B/s+200ms、25秒500000B/s+40ms。normal/normal-repeat保持repeat-stall-budget-diagnostic-v1：0秒500000B/s+40ms、10秒停流、15秒2000000B/s+0ms、60–65秒再次停流、之后2000000B/s+0ms。120秒自有素材，close模式。

955000bps、双8秒/每窗口3请求、缓冲5秒/剩余20秒、每源2次预算、500/1000ms退避、准备2秒/票据5秒全部不变；取消请求仍参与关联分母，成功请求全部事务核心时长仍必须完整。

| 场景 | 真实安装数 | 第二次高档尾部秒 | EOF位置秒/宽度 | 替换边界新帧间隔ms | 全程最大新帧间隔ms | 严格回执 |
| --- | --- | --- | --- | --- | --- | --- |
'''
for n in ['normal','original','normal-repeat','original-repeat']:
 v=q[n];f=v['final'];proof=v['secondInstallProof'];gaps='/'.join(f'{b["publicationGapMs"]:.3f}' for b in v['continuity']['replacementBoundaries']) or '无替换';tail=f'{proof["highTailSeconds"]:.3f}' if proof else '无第二次安装';installs=sum(e['outcome']=='installed' for e in f['automaticEvents'])
 s+=f'| {n} | {installs} | {tail} | {f["position"]:.6f}/{f["width"]} | {gaps} | {v["continuity"]["maximumPublishedFrameGapMs"]:.3f} | '+('通过' if v['receiptPassed'] else '失败')+' |\n'
s+=f'\n严格回执{a["strictPasses"]}/4，独立重算{a["reassessedPasses"]}/4；原生探针通过不能覆盖严格证据失败。\n'
for n,v in q.items():
 phases=' → '.join(f'{phase["elapsed"]:.3f}秒/{phase["width"]}宽' for phase in v['publishedPhases'])
 s+=f'\n- {n}：nativeExitCode={v["nativeExitCode"]}；{phases}；预约/票据={len(v["reservations"])}/{len(v["tickets"])}；严格错误='+json.dumps(v['receiptErrors'],ensure_ascii=False)+'。\n'
s+='''
原配置自然高档不计自动安装覆盖。两次诊断安装仍要求第一次安装后高档、再次低档、第二次安装后新generation高档顺序成立。高档尾部/新帧发布间隔是采样证据，不是物理屏幕或音频测量，continuityAccepted、physicalOutputVerified、audioSynchronizationVerified、capabilityAccepted均false，不声称缩短了空档。

## 资源关系与取消定位
'''
for n,v in q.items():
 d=ca['yl-resource-correlation/'+n];rel=relations[n];s+=f'\n{n}：proxy={v["proxyCount"]}，取消={d["cancellations"]}，原因分布={json.dumps(d["cancelCauseCounts"])}，未关联取消={len(d["uncorrelated"])}，资源分组={rel["distinctProxyResources"]}；服务器接入/解析={v["lifecycle"]["acceptedCount"]}/{v["lifecycle"]["parsedRequests"]}。\n'
 for b in rel['uncorrelated']:
  s+=f'\n未关联requestID={b["requestID"]}，cause={b["cancelCause"]}，接入至关闭{b["downstreamLifetimeMs"]:.3f}ms；根据其他逐请求已关联记录得到的同URL资源候选='+json.dumps(b['relatedServerAssetCandidates'])+'；取消后完成的同URL请求='+json.dumps([dict(requestID=x['requestID'],afterMs=round(x['admissionRelativeToCancellationMs'],3),asset=x['asset']) for x in b['laterCompletedSameURLRequests']])+'。原请求serverRequestID仍为null，资源候选不构成其已到达服务器的证据。\n'
total=sum(v['proxyCount'] for v in q.values());cancelled=sum(v['settlement']['cancelled'] for v in q.values());incomplete=sum(v['settlement']['incompleteMetrics'] for v in q.values());missing=sum(len(v['settlement']['metricsMissing']) for v in q.values());multi=sum(len(v['multipleTransactions']) for v in q.values());bad=sum(len(v['incompleteSuccessfulRequests']) for v in q.values())
s+=f'\n合计{total}条proxy、{cancelled}条取消；核心区间不完整metrics={incomplete}条、完全缺metrics={missing}条、不完整成功事务={bad}条、双事务记录={multi}条。非空不等于完整，原始字段全部保留。\n'
s+='''
本轮四轮未复现未关联快取消，不能据此把历史失败标为修复。资源标识现在能观察同URL请求关系，但尚没有带token的未关联快取消可供定位；旧记录也不能补造token。

normal中音频尾段network-period-4/chunk-2-00005.m4s的request60因EOF取消后约25.002ms，request65再次请求同一URL并再次取消；距request60取消约6028.512ms（距request65取消约4002.543ms）后，request78开始并完成同URL请求。这里比较的是同代理相同URL，不能不经range/凭据/内容验证就声称相同字节被重试成功。

已逐请求关联的高/低档视频也提供了邻近事件：normal的640宽init-1/request61和chunk-1/request62取消后，320宽init-0/request63分别在12.052/10.372ms后接入；normal-repeat的640宽chunk-1/request59取消后，320宽init-0/request61在15.132ms后接入。资源类型和宽度来自自有MPD，各请求资产来自它自己的correlationID匹配；时间差使用同代理uptime。这些事件早于恢复替换，支持继续检查下游ABR请求切换过程，但时间邻近不能证明AVPlayer内部决定或移植到历史未关联请求。transition-context.json和video-transition-pairs.json保留全部输入与推导。

resource-relations.json保存同代理资源分组中的全部取消及关联请求、相对时刻和真实服务器路径/range，failure-cause-analysis.json保留未关联任务及同代理任务寿命上下文。只有原correlationID能建立逐请求服务器关系；资源标识只用于观察同URL请求前后发生了什么，不能说明AVPlayer内部取消决定。

旧v4/v5失败没有资源token，无法追补身份。上轮已在实际媒体复现下游EOF、无requestStart记录、无服务器解析对应请求，并且接入时同一proxy只有自身尚未完成；受控单名额取消可以产生同类日志，但实际Foundation连接占用和AVPlayer触发条件仍未证明。新资源关系也不能补造这一缺失证据。

## 归档、发布台账及未完成项

[完整证据](evidence/2026-10-29-ios-resource-correlation/README.md)包含8份完整xcresult（红、绿、两平台矩阵、四轮媒体）、原始收据/帧/策略/事务/服务器记录、资源分析和源码/制品身份。当前失败与历史失败均保留。
'''
s+=f'\n历史{len(history)}组{sum(x["files"] for x in history)}条哈希逐项核对与9d43d6b4一致。生产源码绑定更新为{source["sha256"]}；102行implementation/verification/acceptance不提升。全局旧evidence定义及报告链保留，CAP-ABR/iOS维持20个直接引用上限，最近直接引用由上轮报告轮替为本报告，开头链接旧报告。\n'
s+='''
台账结构/15项回归/性能注册表/diff检查通过，sourceMatches=true、releaseReady=false，两个--require-ready仍按未满足条件退出1。不发布、不推送、不合并。

继续保留：AVPlayer取消的具体诱因、严格未关联请求、历史双事务、真实网络和更多设备稳定性、预算耗尽后的自然高档、更多提交后故障/生命周期竞争、历史macOS就绪超时诱因；物理音画、更多设备/最低系统和授权媒体等缺口。不恢复已取消的旧终末停顿待办，不授予整体ABR/连续性验收。
'''
p.write_text(s)
l=Path('tool/release_readiness/inventory.json');d=json.loads(l.read_text());key='ios-resource-correlation-20261029';d['source']=source;d['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in d['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[e for e in row['evidence'] if e!='ios-queued-cancel-20261029']
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-avplayer-resource-retry-cancel-cause-strict-correlation-stability-and-physical-av'
l.write_text(json.dumps(d,indent=2)+'\n')
