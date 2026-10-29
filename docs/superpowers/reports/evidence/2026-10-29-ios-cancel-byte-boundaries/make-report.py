from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-cancel-byte-boundaries');a=json.loads((r/'analysis.json').read_text());b=json.loads((r/'byte-analysis.json').read_text());history=json.loads((r/'prior-evidence.json').read_text());probes=json.loads((r/'probe-analysis.json').read_text());assert a['totalRuns']==2
p=Path('docs/superpowers/reports/2026-10-29-ios-cancel-byte-boundaries.md')
s='''# iOS 默认连接池取消与事务字节边界

基线524f31a0，承接[事务字节计数排障](2026-10-29-ios-transaction-bytes.md)。用户授权准备后约6分钟前台采集。原失败与设备/授权缺口保留，沿用集中验收，不放宽门槛，不发布。

## 本轮实现与调查边界

新增诊断摘要byteEvidence只处理已经过严格校验的Foundation原始计数。无metrics、无事务、旧版本无计数、v3截断显式区分；请求/响应各自只有两项计数均明确0才分类zero，任何一项正数为positive，剩余为unknown。原始数字、空值、时间状态和事务序号保留；完整性、成功事务时间及逐请求服务器关联门槛不变。正数字节不证明服务器解析，零字节不证明物理链路没有数据。两个证明标记保持false。该修复完善诊断解释，不修改生产请求/取消/重试/恢复策略。

新增真实socket对照使用默认连接池、新代理且无先行任务，完整GET与EOF一起发送。测试服务器仅用响应门闩防止取消前成功，没有预先占用上游名额。每次取消后显式请求同一资源，记录独立correlation ID、同代理resourceToken、成功正文和服务器解析快照；六次样本全部保留，不预设事务个数或取消ID是否在快照中。服务器fixture仅一次receive解析请求头，快照不能证明请求绝未发送或永不稍后到达。显式后续请求不代表AVPlayer自动重试。

## 集中测试与复审

Python新诊断先红后绿（12项定向，新增3项）；最终工具200/200，消费者46项中45通过、1项既有focused历史证据跳过。本轮选定原生矩阵iPhone252/252、macOS227/227通过并绑定唯一执行身份；canonical全部注册数879/923，本轮没有执行全部注册用例。只新增一个原生测试方法。438份源码/工具输入、307份iPhone制品文件冻结，采集前后核对一致。生产源码指纹沿用524f31a0；Android/Dart未变，本轮未重跑其完整矩阵。

原生首轮对照因新断言将既有Double字段读取为Int失败；修正测试后定向1/1通过，完整失败与通过xcresult均保留。独立复审发现P2：observer通知早于交付清理，清零断言可能竞态；补capture.wait后用最终两平台选定矩阵验证并定向复审闭合。初次工具套件受沙箱socket绑定限制（3失败/33错误），提权重跑完整200通过；消费者首次正确检测新增方法导致计数不符，更新注册表后45通过/1跳过。运行/并发/链接警告原样保留，不声称零警告。

恢复执行时发现一份没有回执的未完成normal目录且无活动采集进程，原文件及哈希完整迁移到media-incomplete-at-resume，终止原因未知；它不算已完成测试或通过。两轮完成采集使用新目录，未覆盖该材料。辅助离线脚本初次把旧原始错误文案与此前重分析混比，改用上轮归档的重分析作对照；旧原始数据不改。

## 受控事务观察

| 执行 | 默认池空事务样本 | 默认池单事务零计数样本 | 受控关闭的事务数/服务器解析数 |
| --- | --- | --- | --- |
'''
for run in ('native-probe-fixed','ios-final','macos-final'):
 samples=probes[run+'/unoccupied']['samples'];empty=sum(v['trace']['metrics']['transactionCount']==0 for v in samples);zero=sum(any(t['request']=='zero' and t['response']=='zero' for t in v['metrics']['byteEvidence']['transactions']) for v in samples)
 forced=probes.get(run+'/forced');f='未跑该对照' if forced is None else str(forced['samples'][0]['trace']['metrics']['transactionCount'])+'/'+str(len(forced['samples'][0]['matchedServerParseIndices']))
 s+=f'| {run} | {empty}/6 | {zero}/6 | {f} |\n'
s+='''
修正字段类型后的macOS短对照在6次中观察到1次单事务、四项计数0且取消ID不在快照，另5次为空事务；这早于交付屏障修正，不能当最终源码选定矩阵。屏障仅在取消完成后等待清理，不改变先前发送/取消决策；两批生产代码相同，但竞态分布不能跨批次归纳为概率。最终两平台各6次均为空事务。观察支持“不需要先占用连接名额也可出现类似边界”，不能确认历史AVPlayer关闭决定或物理发包情况。所有显式同资源后续请求成功。

两平台受控响应前关闭均为2事务、服务器解析同一task ID两次：首事务request正数、response零且响应日期缺失，第二事务request/response正数且时间完整。逐任务保留服务器解析ID列表及重复项，不将解析序号强行对应事务序号。历史一次接入的双事务仍缺可重现诱因；旧v2没有字节计数，不能追补为零。单连接占位对照两平台均为空事务，不与零计数混同。

## 新真机长素材

沿用120秒自有DASH、close连接：normal为repeat-stall-budget-diagnostic-v1（10–15及60–65秒停流，恢复2000000B/s/0ms），original为down-and-recover-v1（10秒50000B/s/200ms，25秒恢复500000B/s/40ms）。955000bps、双8秒窗口/每窗3请求、缓冲5秒、剩余20秒、每源2次预算、500/1000ms退避、准备2秒/票据5秒不变。

| 场景 | 实际安装 | 第二次高档尾部秒 | EOF位置/宽度 | 替换新帧间隔ms | 全程最大新帧间隔ms | 严格结果 |
| --- | --- | --- | --- | --- | --- | --- |
'''
for n,v in a['results'].items():
 f=v['final'];proof=v['secondInstallProof'];tail=f'{proof["highTailSeconds"]:.3f}' if proof else '未建立';gaps='/'.join(f'{g["publicationGapMs"]:.3f}' for g in v['continuity']['replacementBoundaries']) or '无替换';s+=f'| {n} | {sum(e["outcome"]=="installed" for e in f["automaticEvents"])} | {tail} | {f["position"]:.6f}/{f["width"]} | {gaps} | {v["continuity"]["maximumPublishedFrameGapMs"]:.3f} | '+('通过' if v['receiptPassed'] else '失败')+' |\n'
s+=f'\n完成采集严格{a["strictPasses"]}/2，独立重算{a["reassessedPasses"]}/2；另有上述无回执中断材料保留。原生测试通过不覆盖严格媒体失败。\n'
for n,q in a['results'].items():
 v=b[n];s+=f'\n- {n}：proxy={v["proxyCount"]}，取消={v["cancelled"]}，缺metrics={v["missingMetrics"]}，空事务={v["zeroTransactionMetrics"]}，双事务={v["multiTransactions"]}，未关联={v["uncorrelated"]}；错误='+json.dumps(q['receiptErrors'],ensure_ascii=False)+f'；服务器接入/解析={q["lifecycle"]["acceptedCount"]}/{q["lifecycle"]["parsedRequests"]}。\n'
 for d in v['details']:
  s+=f'  request{d["requestID"]}、proxy={d["proxyID"]}、cancelCause={d["cancelCause"]}、寿命{d["downstreamLifetimeMs"]:.3f}ms、serverID={d["correlatedServerRequestID"]}；计数='+json.dumps([t['transportBytes'] for t in (d['metrics'] or {}).get('transactions',[])])+'。\n'
s+='''
实际installed事件及首次高档→再次低档→新generation高档帧序列才构成重复恢复证据；原配置自然升档不补自动安装覆盖。任何缺服务器关联取消或成功事务缺日期继续失败，resourceToken不能借用另一请求的服务器ID。数字帧间隔不等于校准物理显示/音画同步，连续性与整体能力标记仍false。播放器生产代码未变，本轮通过只增加样本，不能归因为恢复策略修复或关闭历史失败。

## 归档、台账与未完成项

[原始证据](evidence/2026-10-29-ios-cancel-byte-boundaries/README.md)保留原生初次失败/修正定向、最终iPhone/macOS矩阵、两轮完成采集共6个完整xcresult，另有未完成xcresult目录及所有原始请求、时间、帧、策略、计数与回执。旧6轮只做离线重算，严格结果保持3/6，含历史双事务和快取消失败；不算新增真机执行。42组历史证据哈希核对不变。

台账102行implementation/verification/acceptance不升级，既有全局evidence保留，CAP-ABR/iOS最近直接引用轮替并链向旧报告；生产指纹不变。结构/注册表及15项台账回归通过，sourceMatches=true、releaseReady=false，两个require-ready继续退出1。独立综合复审结果见review-code.md和review-final.md。不推送、不合并、不发布。

仍未完成：历史AVPlayer下游EOF/旧代理cancelAll的内部关闭原因，历史一次接入双事务首事务缺响应诱因，实际网络/更多设备稳定性，预算耗尽后自然高档，更多提交后故障与生命周期竞争，历史macOS就绪超时；物理显示/音画同步、最低系统及更多设备、授权媒体缺口。旧终末停顿待办不重新加入。没有足够证据支持改变生产取消、传输或重试行为，相关根因继续开放。
'''
s+=f'\n本轮历史核对：{len(history)}组、{sum(v["files"] for v in history)}条归档哈希。\n'
p.write_text(s)
l=Path('tool/release_readiness/inventory.json');d=json.loads(l.read_text());key='ios-cancel-byte-boundaries-20261029';d['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in d['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[v for v in row['evidence'] if v!='ios-transaction-bytes-20261029']
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-default-pool-cancellation-historical-double-transaction-and-physical-av'
l.write_text(json.dumps(d,indent=2)+'\n')
