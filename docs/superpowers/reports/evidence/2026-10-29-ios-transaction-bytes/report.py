from pathlib import Path
import json,hashlib,subprocess
r=Path('/private/tmp/yl-transaction-bytes');a=json.loads((r/'analysis.json').read_text());assert a['totalRuns']==2
b=json.loads((r/'byte-analysis.json').read_text());probes=json.loads((r/'probe-analysis.json').read_text());history=json.loads((r/'prior-evidence.json').read_text());source=json.loads((r/'production-source.json').read_text());p=Path('docs/superpowers/reports/2026-10-29-ios-transaction-bytes.md')
s='''# iOS 事务传输计数与快取消排障

基线d5f437f4，承接[失败回执保留](2026-10-29-ios-failure-observations.md)。用户授权构建后约6分钟前台采集；保留原失败、设备/授权缺口，不放宽门槛，不发布。

## 调查依据与本轮实现

既有受控首请求响应前关闭测试已证明能诱发成功双事务，首事务响应日期缺失；历史长素材只有一次服务器接入，不能把该受控原因移植给历史失败。旧指标不能区分requestStart日期存在与Foundation报告传输多少字节。本轮补上该诊断边界。

YlHlsMediaProxy仅DEBUG诊断增加URLSessionTaskTransactionMetrics四项计数：请求头/请求体已发送、响应头/响应体已接收。来源为当前Xcode SDK Foundation/NSURLSession.h公开属性（iOS13/macOS10.15起可用，低于本项目最低系统）。负Int64转null，0保持0，禁止把未知填零。嵌套metrics升级v3，外层保持带资源标识的v6；不输出URL、地址、端口、凭据、请求头值，不修改请求、取消、重试、恢复策略。

Python兼容旧metrics v1/v2；v3四计数字段完整且仅允许null或非负Int64整数，拒绝bool、浮点、负数、越界、额外/缺失字段。仅外层v6可携带v3。计数是Foundation报告的传输量，不能等同包捕获、服务器解析或物理显示；空transactions与null都不是零。成功事务时间完整性及逐请求关联仍原样要求，计数不能修复它们。

## 测试及独立复审

解析红测1项预期失败，原生受控macOS红测因缺新版本/计数字段失败；完整xcresult保留。最小实现后定向原生通过。独立复审发现P2：外层v2绕过新版本限制；新增outer2反例红测后修复，定向复核outer2–5均拒绝nested3，outer6接受，P2闭合。最终独立证据/台账复审无未关闭P1/P2（review-code.md、review-final.md）。

最终工具197/197、消费者46中45通过1项既有focused证据跳过；iPhone251/251、macOS226/226实际完整矩阵通过并绑定唯一用例身份。没有新增原生方法计数，扩展既有受控测试。438份最终输入、307份新iPhone制品冻结；复审前工具输入/日志另存，P2仅Python修复不改变已测原生制品。Dart/Android未改，本轮未重跑其全矩阵。旧v2四轮离线重算仍2/4，原始JSON/JSONL与回执哈希不变；不计为新增真机执行。Xcode运行/链接/并发警告保留，不声称零警告。附件导出曾被TestReport写权限拦截，使用权限重试成功；不作为测试失败或静默跳过。

## 受控边界观察

| 执行 | 第一事务请求头发送 | 第一事务响应头/体接收 | 第二事务请求头发送 | 第二事务响应头/体接收 |
| --- | --- | --- | --- | --- |
'''
for n,v in probes.items():
 if n.endswith('/forced'):
  x,y=[t['transportBytes'] for t in v['trace']['metrics']['transactions']];s+=f'| {n} | {x["requestHeaders"]} | {x["responseHeaders"]}/{x["responseBody"]} | {y["requestHeaders"]} | {y["responseHeaders"]}/{y["responseBody"]} |\n'
s+='''
三次受控关闭均由服务器解析同一task correlationID两次，首次不给响应、第二次给4字节正文；首事务缺responseStart/responseEnd但请求头计数为正，第二事务时间完整。受控记录用于解释Foundation指标，不是严格媒体回执，不按去重或补时间来取得通过。该表不能解释历史一次接入的缺响应事务。

完整iPhone/macOS矩阵中的受控单连接名额快取消均为0个transactions：这里没有可用的每事务计数，不能写成“每事务计数0”。其原取消ID仍不在服务器解析列表，随后显式同URL请求可成功；这是受控调用方行为，不是AVPlayer自动重试的证明。原始forced与queued附件、跟随请求和服务器关联ID均保留。

## 两轮新真机长素材

normal为repeat-stall-budget-diagnostic-v1（10–15及60–65秒停流，恢复2000000B/s/0ms）；original为down-and-recover-v1（10秒50000B/s/200ms，25秒恢复500000B/s/40ms）。都用120秒自有素材、close连接模式。955000bps、双8秒窗口/每窗3请求、缓冲5秒/剩余20秒、每源2次预算、500/1000ms退避、准备2秒/票据5秒不变。

| 场景 | 实际安装 | 第二次高档尾部秒 | EOF位置/宽度 | 替换新帧间隔ms | 全程最大新帧间隔ms | 严格结果 |
| --- | --- | --- | --- | --- | --- | --- |
'''
for n,v in a['results'].items():
 f=v['final'];proof=v['secondInstallProof'];tail=f'{proof["highTailSeconds"]:.3f}' if proof else '无第二次安装';gaps='/'.join(f'{g["publicationGapMs"]:.3f}' for g in v['continuity']['replacementBoundaries']) or '无替换';s+=f'| {n} | {sum(e["outcome"]=="installed" for e in f["automaticEvents"])} | {tail} | {f["position"]:.6f}/{f["width"]} | {gaps} | {v["continuity"]["maximumPublishedFrameGapMs"]:.3f} | '+('通过' if v['receiptPassed'] else '失败')+' |\n'
s+=f'\n严格{a["strictPasses"]}/2，独立重算{a["reassessedPasses"]}/2。原生探针通过不覆盖严格证据失败。\n'
for n,v in b.items():
 q=a['results'][n];s+=f'\n- {n}：proxy={v["proxyCount"]}，取消={v["cancelled"]}，缺metrics={v["missingMetrics"]}，0事务={v["zeroTransactionMetrics"]}，双事务={v["multiTransactions"]}，未关联={v["uncorrelated"]}；errors='+json.dumps(q['receiptErrors'],ensure_ascii=False)+f'；服务器接入/解析={q["lifecycle"]["acceptedCount"]}/{q["lifecycle"]["parsedRequests"]}。\n'
 for d in v['details']:
  counts=[t['transportBytes'] for t in (d['metrics'] or {}).get('transactions',[])];s+=f'\n  proxy={d["proxyID"]}/request{d["requestID"]}，cancelCause={d["cancelCause"]}，寿命{d["downstreamLifetimeMs"]:.3f}ms，serverID={d["correlatedServerRequestID"]}，计数='+json.dumps(counts)+'。\n'
s+='''
normal的未关联request63再次与此前已关联的高档分片request62同代理同resourceToken；前一服务器ID仍只归属于62。其单事务fetchToRequestSeconds缺结束日期，四计数Foundation均报告0：与取消早于已记录请求发送的解释一致，不能证明物理链路没有数据或确定AVPlayer内部关闭决策。它仍是严格失败，不能强迫已取消请求抵达服务器来制造关联。

只有实际installed事件及“首次高档→再次低档→新generation高档”帧序列才记作重复恢复；原配置自然升档不补自动安装覆盖。新增诊断可能扰动极短时序，不据跨批次间隔差异宣称性能修复。连续性、物理输出、音画同步及整体能力标记继续false。本轮不能为旧无计数记录追补数值或关闭历史双事务失败。

## 归档、台账与未完成项

[完整原始证据](evidence/2026-10-29-ios-transaction-bytes/README.md)包含6个完整xcresult（红/绿定向、两平台完整矩阵、两轮新采集）、原始附件、错误与跳过、事务计数/帧/策略/服务器记录、输入制品身份及复审。旧证据不覆盖。
'''
s+=f'\n历史{len(history)}组{sum(v["files"] for v in history)}条哈希与d5f437f4核对一致。生产指纹更新为{source["sha256"]}，仅DEBUG代理文件内容变化。102行implementation/verification/acceptance不升级；旧全局evidence保留，CAP-ABR/iOS仍20直接引用，最近报告轮替且链向旧报告。台账结构、15项回归及注册表通过，sourceMatches=true、releaseReady=false；两个--require-ready继续退出1。不发布、不推送、不合并。\n'
s+='''
仍未完成：AVPlayer下游EOF与旧代理cancelAll未关联的内部原因、历史一次接入双事务的首事务缺响应诱因、实际网络与更多设备稳定性、预算耗尽后自然高档、更多提交后故障与生命周期竞争、历史macOS就绪超时；物理音画、最低系统/更多设备及授权媒体缺口。旧终末停顿待办不重新加入。根因未确认部分不作生产行为修复或整体验收声明。
'''
p.write_text(s)
l=Path('tool/release_readiness/inventory.json');d=json.loads(l.read_text());d['source']=source;key='ios-transaction-bytes-20261029';d['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in d['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[v for v in row['evidence'] if v!='ios-failure-observations-20261029']
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-foundation-byte-boundaries-cancellation-dual-transaction-root-causes-and-physical-av'
l.write_text(json.dumps(d,indent=2)+'\n')
