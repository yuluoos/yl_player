from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-fast-cancel');a=json.loads((r/'analysis.json').read_text());q=a['results'];ca=json.loads((r/'cancellation-analysis.json').read_text())['results'];assert len(q)==4
source=json.loads((r/'production-source.json').read_text());history=json.loads((r/'prior-evidence.json').read_text())
p=Path('docs/superpowers/reports/2026-10-29-ios-fast-cancel.md')
s='''# iOS 快速取消定位与原配置/重复恢复对照

基线 bffe50ea，承接[取消任务收尾](2026-10-29-ios-cancel-settlement.md)。用户授权准备后四轮约12分钟前台采集，沿用系统排障、TDD和集中验收。保留原始失败和设备/授权缺口，不放宽门槛，不发布。

## 本轮实现及证据边界

补齐DEBUG诊断缺失的取消来源。v5 `cancelCause`：0非取消、1整体代理失效、2下游EOF、3下游错误、4其他本地关闭。close/cancelAll的取消行为不变，不延迟取消、不强迫已取消任务发出请求、不补造服务器记录。参数传递在共享方法签名中，实际记录仅在DEBUG；没有调整自动恢复策略或替换实现。

来源随第一次trace.finish记录，晚到回调不能覆盖。它表示最先取得trace锁的终止观察，不保证并发外部事件的真实总顺序。v1–4继续按原规则解析，v5要求原因存在、合法且与outcome一致。成功请求仍需完整事务核心时长和服务器关联，所有取消请求仍参与关联分母，无关联仍严格失败。

原生红测试2项因缺cancelCause失败；修复后定向4项通过。真实测试分别执行cancelAll和下游client.cancel，并等待真实Foundation任务完成；两者都先等服务器进入处理，只证明响应前取消，不能充当请求发出前取消的复现。下游用例允许EOF或错误，不代表两条分支分别执行。来源不被晚回调覆盖的用例为顺序调用，不宣称并发竞态穷尽。

Python新增2项验证缺失/越界/布尔原因被拒绝，取消无服务器关联仍不通过，成功不能标记取消。初次v5不支持失败、未知版本测试尚指向新支持版本5的中间失败全部保留；未知版本用例更新到6后通过，没有削弱校验。真实CLI切换到v5并覆盖读取路径。

## 统一测试与修订绑定

网络工具190/190通过；消费者46项中45通过、1项既有历史focused证据缺失跳过。原生规范源码身份总数仍iOS876/macOS920，并非实际执行数。本轮新制品iPhone249/249、macOS224/224通过，均按规范所选类逐个唯一身份绑定；上轮macOS失败仍完整保留，不因本轮通过宣称历史诱因已解决。

438份源码/工具输入和307份iPhone制品指纹冻结，四轮采集前后相同。Dart/Android生产未改，本轮未重跑其全矩阵。编译及Xcode设备信息警告原样归档，不宣称零警告。独立代码复审无可确认P1/P2，22项边界/CLI独立测试通过；上述来源时序和测试覆盖限制纳入报告。

## 四轮同制品真机采集

original/original-repeat使用原封不动的down-and-recover-v1：0秒500000B/s+40ms、10秒50000B/s+200ms、25秒500000B/s+40ms。

normal/normal-repeat使用repeat-stall-budget-diagnostic-v1：0秒500000B/s+40ms、10秒停流、15秒2000000B/s+0ms、60–65秒再次停流、之后2000000B/s+0ms。120秒自有素材，close模式。诊断配置不能替代原配置验收。

955000bps、双8秒窗口/每窗口3请求、缓冲5秒/剩余20秒、每源2次预算、500/1000ms退避、准备2秒/票据5秒均保持。没有更改音画门槛。

| 场景 | 安装数 | 第二次高档尾部秒 | EOF位置秒/宽度 | 替换边界新帧间隔ms | 全程最大新帧间隔ms | 严格回执 |
| --- | --- | --- | --- | --- | --- | --- |
'''
for n in ['original','normal','original-repeat','normal-repeat']:
 v=q[n];f=v['final'];proof=v['secondInstallProof'];gaps='/'.join(f'{b["publicationGapMs"]:.3f}' for b in v['continuity']['replacementBoundaries']) or '无替换';tail=f'{proof["highTailSeconds"]:.3f}' if proof else '自然恢复';installs=sum(e['outcome']=='installed' for e in f['automaticEvents'])
 s+=f'| {n} | {installs} | {tail} | {f["position"]:.6f}/{f["width"]} | {gaps} | {v["continuity"]["maximumPublishedFrameGapMs"]:.3f} | '+('通过' if v['receiptPassed'] else '失败')+' |\n'
s+=f'\n严格回执{a["strictPasses"]}/4，独立重算{a["reassessedPasses"]}/4。原生媒体探针逐轮结果、全部错误和信号见analysis.json及各原始receipt；通过原生探针不替代严格证据门槛。\n'
for n,v in q.items():
 s+=f'\n- {n}：nativeExitCode={v["nativeExitCode"]}；phase='+' → '.join(f'{phase["elapsed"]:.3f}秒/{phase["width"]}宽' for phase in v['publishedPhases'])+f'；reservations/tickets={len(v["reservations"])}/{len(v["tickets"])}；严格错误='+json.dumps(v['receiptErrors'],ensure_ascii=False)+'。\n'
s+='''
原配置自然高档恢复不计自动安装覆盖；两次诊断安装要求第一次安装后高档、再次低档、第二次安装后新generation高档顺序成立，不能只用attempts计数。持续高档尾部和恢复完整顺序详见secondInstallProof。发布层采样不是物理屏幕或声音测量；所有continuityAccepted、physicalOutputVerified、audioSynchronizationVerified、capabilityAccepted仍false，不宣称已缩短新帧空档。

## 快速取消定位

上轮两条未关联记录位于播放约12.8秒：附近采样区间12.579–12.845秒与12.544–12.797秒，均早于首次安装约37.769/38.259秒。使用同设备sampleUptime做邻近采样括区，elapsed和sampleUptime并非同一次读取，不将其当精确跨时钟换算。这个时间关系排除“那两次首次恢复替换造成取消”的解释，但旧版本没有原因字段，不能追补具体下游原因。
'''
for n in ['original','normal','original-repeat','normal-repeat']:
 d=ca['yl-fast-cancel/'+n];v=q[n]
 s+=f'\n{n}：代理{v["proxyCount"]}条；取消{d["cancellations"]}条，来源分布{json.dumps(d["cancelCauseCounts"])}；服务器接入/解析{v["lifecycle"]["acceptedCount"]}/{v["lifecycle"]["parsedRequests"]}；未关联取消{len(d["uncorrelated"])}条。\n'
 for b in d['uncorrelated']:
  s+=f'\n未关联requestID={b["requestID"]}、cancelCause={b["cancelCause"]}、taskOutcome={b["taskOutcome"]}，下游生命周期{b["downstreamLifetimeMs"]:.3f}ms，邻近播放采样{json.dumps(b["nearbyPlaybackSamples"])}；bodyBytes={b["bodyBytes"]}、sendCount={b["sendCount"]}；首次安装前={b["recordedBeforeFirstInstall"]}。事务原字段见cancellation-analysis.json及proxy-requests.jsonl。\n'
s+='''
四轮1513条代理记录全部保留taskComplete和非空metrics；39条取消均为下游EOF，其中32个Foundation任务最终取消、7个任务最终成功但下游已关闭。28条取消的核心事务区间不完整仍如实保留，成功请求无不完整事务；非空不等于完整。本轮无双事务、无后台/音频路由信号、无hostFailure，服务器生命周期没有拒绝、无请求连接或遗漏。

normal-repeat复现同一首次停流阶段的一条短取消：proxy requestID63、server requestID65，约12.532–12.787秒附近，生命周期11.526ms、cancelCause=2、taskOutcome=1；body/send仍0，但Foundation记录connect=7.000ms、fetch→request=10.856ms、request=0.108ms，并由服务器真实解析到同一correlationID。服务器body写出0、随后client_io_error，记录不被丢弃。它与历史3.183/4.411ms、无requestStart/无服务器关联形成阶段对照，支持“取消发生时是否已进入HTTP请求阶段”这一解释；不同运行的时序不能证明历史两条的准确根因，也不能把11.526ms当作固定阈值。short-cancel-comparison.json保留双方原始字段。

Apple将fetchStartDate与requestStartDate作为不同的可选时间指标；没有requestStartDate仅表示没有记录到请求开始，不能据此证明网络层从未发字节。[Apple requestStartDate](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics/requeststartdate?changes=_6)。结合下游取消来源、短生命周期及完整服务器生命周期可收窄发生边界，但不能从日志推断AVPlayer内部为何决定取消。不得延迟取消来制造关联，不能删除取消记录或把诊断分类当验收豁免。

本轮未修改传输调度或ABR恢复算法；已确认并修复的是取消原因不可观察的问题。快速取消的严格服务器关联问题、AVPlayer内部取消触发条件和历史双事务确切诱因仍保留。新成功不能改写历史失败。

## 归档与未完成项

[完整证据](evidence/2026-10-29-ios-fast-cancel/README.md)包含原生红/绿与两平台矩阵、四轮完整xcresult，原始收据/帧/策略/代理事务/服务器生命周期，源码/制品身份、分析及复审记录。
'''
s+=f'\n历史{len(history)}组{sum(x["files"] for x in history)}条哈希逐项核对且与bffe50ea一致。台账生产源码指纹更新到{source["sha256"]}；102行implementation/verification/acceptance均不升级，全局历史evidence定义及报告链保留；CAP-ABR/iOS维持20个直接引用上限，将最近的取消收尾报告直接引用轮替为本报告，本报告开头链接该上轮报告，不删除其定义或证据。结构/15项回归/性能注册表/diff检查，sourceMatches=true、releaseReady=false；两个--require-ready预期退出1。\n'
s+='''
仍未完成：原配置和真实网络更广泛稳定性、严格未关联取消、历史双事务诱因、预算耗尽后的自然高档机制、更多提交后故障及生命周期竞争；历史macOS连接就绪超时的具体诱因；物理音画、更多设备/最低系统与授权媒体等缺口。已取消的旧终末停顿不恢复为待办。此次仅补齐已确认诊断缺口及当前条件验证，不升级整体ABR/连续性验收。不发布、不推送、不合并。
'''
p.write_text(s)
l=Path('tool/release_readiness/inventory.json');d=json.loads(l.read_text());key='ios-fast-cancel-20261029';d['source']=source;d['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in d['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[e for e in row['evidence'] if e!='ios-cancel-settlement-20261029']
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-fast-cancel-server-correlation-original-stability-historical-transactions-lifecycle-races-and-physical-av'
l.write_text(json.dumps(d,indent=2)+'\n')
