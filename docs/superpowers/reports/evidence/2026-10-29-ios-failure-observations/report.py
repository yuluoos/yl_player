from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-failure-observations');a=json.loads((r/'analysis.json').read_text());assert a['totalRuns']==2
replay=json.loads((r/'replay-results.json').read_text());source=json.loads((r/'production-source.json').read_text());history=json.loads((r/'prior-evidence.json').read_text())
p=Path('docs/superpowers/reports/2026-10-29-ios-failure-observations.md')
s='''# iOS 失败回执保留与重复恢复复核

基线66d12aa3，承接[同资源取消回归与原始失败](2026-10-29-ios-same-resource-retry.md)。继续已授权的未完成项，保留失败、设备及授权缺口，不放宽门槛，不发布。

## 已确认并修复的问题

上轮normal中，一个成功请求的双事务首事务没有responseStart/responseEnd，严格校验抛出ValueError，提前退出整个回执生成，导致其他请求关联失败、策略、帧连续性及生产恢复观察未进入回执。底层网络/AVPlayer原因仍不确定，本轮修复的是这一确定的诊断丢失。

proxy_boundaries的严格summarize接口仍以ValueError子类拒绝成功任务的不完整事务。只有全部记录的结构、身份、时序、字节等其他条件校验通过，才随错误携带诊断快照；所有成功任务不完整事务的proxyID/requestID都保留。record调用将失败写入errors，保留快照并继续其他独立观察。畸形记录不输出可信快照，不回显未校验的字段或异常内容。取消请求不被删除、豁免或使用同资源token匹配。

bandwidth_diagnostics输出可读JSON失败详情且非零退出；原先仅缺关联时CLI可退出0，本轮明确改为1，与严格回执失败一致。它不覆盖采集回执，也不授予能力验收。最终passed仍要求errors为空；全部事务完整性、955000bps、双8秒窗口/每窗口3请求、缓冲5秒/剩余20秒、2次预算及500/1000ms退避均不变。

## 红测与统一测试

修改前新增回归复现：proxy 2项、CLI 1项、回执后续帧1项预期失败；原因分别为抛异常中止、无JSON输出、帧观察未写入。修复后定向18/7/40项通过；随后增加后续畸形记录不能暴露部分快照及CLI缺关联非零断言，最终工具195/195通过。消费者46项中45通过、1项既有focused历史证据跳过。最初消费者发现目录错误运行0项、退出5，原日志保留为consumer-wrong-discovery.log，不计通过；修正目录后才记录上述46项。

本轮5个工具/测试Python文件变化，生产播放器与原生测试均不变。438份输入留存采集及最终快照；采集后仅去除一个测试文件末尾多余空行，AST一致并定向复测，见post-capture-whitespace.json。307份iPhone制品与66d12aa3采集完全相同。因此复用该修订iPhone251/macOS226矩阵，明确未重新执行该原生全矩阵、Dart/Android全矩阵或重新构建；本轮新增真机长素材单独列出。生产源码指纹仍与台账一致。独立代码及最终证据/台账复审无P1/P2，记录见review-code.md与review-final.md。

## 对历史四轮的离线重算

replay.py调用实际校验及帧/策略/生产恢复汇总函数；这是旧数据重算，不是新增设备运行，不修改原回执或原始日志。

| 历史场景 | 原严格结果 | 新重算 | 代理数 | 未关联数 | 当前诊断 |
| --- | --- | --- | --- | --- | --- |
'''
for n,v in replay.items():s+=f'| {n} | {v["oldPassed"]} | {v["newPassed"]} | {v["proxyCount"]} | {v["uncorrelated"]} | '+', '.join(v['errors'])+' |\n'
s+='''
仍为2/4。normal同时保留C459…/request4成功双事务不完整及未关联取消，四轮都可独立汇总帧观察。normal-third的4条缺关联保持失败，CLI亦退出1。每轮重算前后对所有原始顶层JSON/JSONL及回执逐项验哈希不变；完整历史归档另行核对。

## 两轮新增真机采集

用户本轮确认约6分钟前台窗口。沿用未变制品：normal使用repeat-stall-budget-diagnostic-v1（10–15秒及60–65秒停流，恢复2000000B/s+0ms）；original保持down-and-recover-v1（10秒50000B/s+200ms，25秒恢复500000B/s+40ms）。两轮均120秒自有素材、close模式。门槛和原配置未调整。

| 新场景 | 安装数 | 高档尾部秒 | EOF位置/宽度 | 替换新帧间隔ms | 全程最大新帧间隔ms | 严格回执 |
| --- | --- | --- | --- | --- | --- | --- |
'''
for n,v in a['results'].items():
 proof=v['secondInstallProof'];tail=f'{proof["highTailSeconds"]:.3f}' if proof else '无第二次安装';gaps='/'.join(f'{b["publicationGapMs"]:.3f}' for b in v['continuity']['replacementBoundaries']) or '无替换';f=v['final'];s+=f'| {n} | {sum(e["outcome"]=="installed" for e in f["automaticEvents"])} | {tail} | {f["position"]:.6f}/{f["width"]} | {gaps} | {v["continuity"]["maximumPublishedFrameGapMs"]:.3f} | {v["receiptPassed"]} |\n'
s+=f'\n新增严格{a["strictPasses"]}/2，独立重算{a["reassessedPasses"]}/2；历史重算与本轮新采集分开计数。\n'
for n,v in a['results'].items():
 d=json.loads((r/'media'/n/'receipt.json').read_text());s+=f'\n- {n}：nativeExitCode={v["nativeExitCode"]}；proxy={v["proxyCount"]}，cancelled={v["settlement"]["cancelled"]}；严格errors='+json.dumps(v['receiptErrors'],ensure_ascii=False)+'；重算errors='+json.dumps(v['errors'],ensure_ascii=False)+f'；连续性字段存在={"continuityObservation" in d}；预约/票据={len(v["reservations"])}/{len(v["tickets"])}。\n'
 phases=' → '.join(f'{v["elapsed"]:.3f}秒/{v["width"]}宽' for v in v['publishedPhases']);s+='\n  发布帧档位：'+phases+'。\n'
s+='''
normal仅以真实installed事件和帧“高→低→新generation高”序列判定观察到两次恢复，不把attempts或预约当安装。original自然升档不能补自动恢复覆盖。采样帧间隔不等于物理播放连续性；continuityAccepted、physicalOutputVerified、audioSynchronizationVerified、capabilityAccepted继续false，未宣称本轮缩短新帧空档或修复AVPlayer内部行为。

新增normal复现同代理高档分片request62下游关闭后5.499ms准入同URL request63，后者2.547ms后因下游EOF取消；无自己的服务器关联，无后续成功同URL请求。同token只给出原始URL身份，不能回填服务器64（它归属于62），不能认定method/range或取消内部原因。该失败回执保留proxy、policy、continuity及productionRecovery观察。两轮新采集均未复现双事务，相关失败分支的验证依据是上轮原始数据回放和回归用例。

## 归档与台账

[完整证据](evidence/2026-10-29-ios-failure-observations/README.md)保存红/绿测试、错误发现命令、旧数据新重算、2个新增完整xcresult及原始日志、输入与制品身份、独立复审。旧证据不覆盖。
'''
s+=f'\n历史{len(history)}组{sum(x["files"] for x in history)}条哈希与66d12aa3核对一致。102行implementation/verification/acceptance不升级，旧全局evidence定义保留；CAP-ABR/iOS的20条直接引用仅轮替最近报告，旧报告由本报告和全局表保留。台账结构及15项回归通过，sourceMatches=true、releaseReady=false；两个--require-ready依旧退出1。\n'
s+='''
未完成：实际AVPlayer下游EOF取消及旧代理cancelAll未关联的根因、成功双事务首事务缺响应的来源/历史诱因、真实网络和更多设备稳定性、预算耗尽后的自然高档、更多提交后故障及生命周期竞争、历史macOS就绪超时诱因；物理音画、最低系统、更多设备及授权媒体缺口。已取消的旧终末停顿不重新列入。此次诊断修复不关闭这些失败，不授予整体ABR或物理连续性验收。不发布、不推送、不合并。
'''
p.write_text(s)
l=Path('tool/release_readiness/inventory.json');d=json.loads(l.read_text());assert d['source']==source;key='ios-failure-observations-20261029';d['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in d['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[v for v in row['evidence'] if v!='ios-same-resource-retry-20261029']
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-native-cancellation-and-dual-transaction-root-causes-stability-and-physical-av'
l.write_text(json.dumps(d,indent=2)+'\n')
