from pathlib import Path
import json,hashlib,subprocess
r=Path('/private/tmp/yl-loopback-error-source');p=Path('docs/superpowers/reports/2026-10-29-loopback-error-source.md')
a=json.loads((r/'analysis.json').read_text());e=json.loads((r/'error-analysis.json').read_text());b=json.loads((r/'byte-analysis.json').read_text());q=json.loads((r/'request-analysis.json').read_text());h=json.loads((r/'high-request-boundaries.json').read_text())
text='''# 回环错误来源区分与预算耗尽恢复验证

基线6b468200，承接[预算耗尽后停留低档对照](2026-10-29-budget-low-cause.md)。用户授权新制品两轮约6分钟前台采集；沿用系统排障、测试驱动、集中验收与独立综合复审。未增加预算、放宽门槛或发布。

## 实施与边界

上轮cancelCause=3合并了连接失败、请求头接收错误和已接纳请求监视接收错误，无法定位入口。本轮只补诊断：HLS代理保持取消/回收语义，v7新增cancelSource（0无已记录取消错误、1 state.failed、2请求头receive、3已接纳请求monitor receive）、cancelErrorDomain（0无、1 POSIX、2 DNS、3 TLS、4未知）和Int32有符号cancelErrorCode。不输出URL、凭据、错误文本、IP或原始日期。仅显式DEBUG捕获记录；非诊断资源释放、半关闭支持和独立截止计时器不变。

trace的第一次终止冻结来源，晚到的另一错误/发送回调和任务完成不会改写；任务仍等待Foundation指标收尾。这里的第一次是trace记录的先后，不是底层事件的绝对物理顺序。头部解析错误若发生在请求接纳前，不存在请求trace，本轮不伪造它；source0还包括outcome已另行标记的发送失败，不表示整次交换没有错误。

严格解析器支持v7并拒绝缺字段、伪造枚举、布尔/浮点/越界错误码、与取消原因矛盾的字段；DNS/TLS负数不会被非负时间校验误拒。v1–v6保持兼容，旧版来源与错误码输出null，禁止反推。当前采集与两个诊断CLI同步升级，成功事务完整性、服务器关联、预算和连续性门槛未降低。

恢复预算仍2，不退款或绕过第三次预约；955000bps、双8秒且每窗至少3请求、缓冲5秒/剩余20秒、500/1000ms退避、准备2秒/票据5秒全部不变。没有强制高档或额外替换。

## 红绿与集中原生验收

先给既有真实取消测试补v7/字段断言：旧实现原生退出65、1失败，缺字段/版本证据保留。解析器新增用例先遇旧版拒绝v7的两处ValueError；首次实现后旧“未来版本7拒绝”断言失败，明确升级未来版本为8，失败日志保留。最终边界23/23，网络工具203/203，消费者45通过/1既有历史focused证据缺失跳过。新注册用例883/927，不能冒充全部执行。

最终新制品iPhone16/iOS27.2选定原生矩阵256/256、macOS231/231，无失败/跳过，执行身份逐项绑定。新增真实SO_LINGER重置探针两平台均记录source3/POSIX54（ECONNRESET），并验证连接、任务、截止计时器归零；允许系统以state.failed或monitor receive先报错，未硬编码回调先后。新增映射冻结用例覆盖POSIX/DNS/TLS/未知映射及晚到错误、正文、任务完成不得覆盖首记录；晚到发送由既有testProxyRequestTimingSealsCancellationAndIgnoresLateSendCompletion验证。既有半关闭完整正文、排队及完整断开/不读取客户端有界回收继续通过。

原生构建/运行中的既有Swift并发、弃用、链接目标和诊断采集警告原样保存；macOS日志还含“command failed with exit code 0”编译诊断，最终矩阵和构建退出0、实际231项均通过，不宣称零警告。iOS devicectl诊断采集只产生部分包，不冒充完整系统诊断。

## 新制品长素材真机采集

同一冻结438输入、307份iPhone制品，两轮120秒自有DASH、close连接、manifest-only准备。budget-throttle复用上轮两次降档profile（第二次60–65秒50000B/s），公开pause-resume取消第一次预约且不退款；normal复用停流profile，无公开暂停。两轮并非仅一个变量不同，不以横向差异作因果证明。两轮都要求真实生产安装；预算轮额外要求耗尽专项，最终640要求不变。

| 场景 | 预约/安装 | EOF/最终宽度 | 替换新帧间隔ms | 最大全程新帧间隔ms | 严格/重算 |
| --- | --- | --- | --- | --- | --- |
'''
for n,d in a['results'].items():
 c=d['continuity'];events=[v for v in d['final']['automaticEvents'] if v['outcome']=='installed']
 # Preserve the complete continuity schema below rather than guessing undocumented fields.
 text+=f"| {n} | {d['final']['automaticAttempts']}/{len(events)} | {d['final']['position']:.6f}/{d['final']['width']} | {'/'.join(format(v['publicationGapMs'],'.3f') for v in c['replacementBoundaries'])} | {c['maximumPublishedFrameGapMs']:.3f} | {d['receiptPassed']}/{d['reassessmentPassed']} |\n"
text+=f"\n严格{a['strictPasses']}/{a['totalRuns']}，独立重算{a['reassessedPasses']}/{a['totalRuns']}。原生运行退出0不替代严格结果。\n"
for n,d in a['results'].items():
 z=q[n]
 text+=f"\n### {n}\n\n最终位置{d['final']['position']}秒，原回执错误={json.dumps(d['receiptErrors'],ensure_ascii=False)}，重算错误={json.dumps(d['errors'],ensure_ascii=False)}。信号={d['signals']}。预算观察={json.dumps(d['budget'],ensure_ascii=False)}。\n\n连续性原始汇总={json.dumps(d['continuity'],ensure_ascii=False)}。正常重复恢复证明={json.dumps(d['secondInstallProof'],ensure_ascii=False)}。\n\n服务器65秒后新高档请求{sum(x['requestCounts'].get('high',0) for x in z['serverClockPhases'][2:])}个，最后高档请求startMs={z['lastHighServerRequest']}；尾段90秒后宽度={z['tail90Seconds']['widths']}。全部原生样本无应用限码率/限分辨率/固定轨道。安装后输出和错误变化={json.dumps(z['postInstallOutput'],ensure_ascii=False)}。\n\n代理{b[n]['proxyCount']}条，取消{b[n]['cancelled']}、发送失败{b[n]['sendFailed']}、未关联{b[n]['uncorrelated']}、缺metrics {b[n]['missingMetrics']}、空事务{b[n]['zeroTransactionMetrics']}、多事务{b[n]['multiTransactions']}。错误入口/域/码分布={json.dumps(e[n]['errorTuples'])}。\n"
text+='''
## 原因结论及未完成项

本轮budget-throttle的最后高档请求为network-period-16/chunk-1-00004.m4s，服务器request229、proxy request50。v7明确记录state.failed（source1）、POSIX54/ECONNRESET先冻结终止记录，而不是monitor receive入口；代理接收并发送65536字节，服务器写到66560字节后client_io_error，素材完整长度68293字节。代理自身接纳到终止2.013931秒；服务器独立时钟下请求60.134483–62.245031秒，总2.110548秒。独立25秒截止没有作为此次首记录终止原因，也未记录为proxy.cancelAll。不能因约2秒就宣称AVPlayer存在已确认的2秒私有超时。

服务器本次高档请求等待共享速率锁0.496552秒、持锁1.596543秒，其中请求sleep1.351680秒、实际sleep1.592798秒；50000B/s是音视频所有连接共享的速率上限，无空闲或过睡信用。因此该对照不是无错误的纯带宽对照，较低有效单请求吞吐不能直接判定为生产代理缺陷。此前59.139332秒开始的高档请求完整60790字节成功；60.134483秒这一请求失败后，新高档请求为0。两段counterfactual带宽约2.797/2.609Mbps仍达门槛，最终320的严格失败保留。

新的来源字段定位的是当前可观察回调入口，不证明AVPlayer为什么发起断开或为什么不再尝试高档。服务器写完整正文也不等于播放器收到完整正文；服务器profile与设备uptime是两个时钟域，不直接相减。详细高档请求边界和后续高档请求计数见high-request-boundaries.json与error-analysis.json；未用旧版cancelCause3伪造具体入口。

预算专项与高档恢复是两个门槛；最终低档即使有两段合格带宽、预算正确耗尽仍是严格失败。当前没有已确认的、预算不变且保持用户策略的恢复行为修复，因此只修复诊断缺口，不把取证完成标为恢复完成。

新制品两平台强制上游首次连接关闭合约仍得到真实双事务，首事务无响应日期，第二次完整；该受控诱因不是历史成功双事务的内部原因。历史v2缺字节计数不能补造；旧6轮重算仍3/6，原失败保留。新媒体有无复现也不关闭历史根因。

没有校准物理屏幕/音频采集，physicalOutputVerified、audioSynchronizationVerified、continuityAccepted、capabilityAccepted仍false。发布新帧间隔与主动暂停全程间隔分列，不据单次或跨批次差异宣称性能改善。继续保留预算耗尽后的自然高档恢复、长期稳定性、更多生命周期竞争、历史双事务及macOS就绪超时、更多设备/最低系统/实际网络/授权素材与物理音画缺口；不重新加入用户删除的旧终末停顿待办。

## 历史、台账与复审

48组10118条历史哈希与基线6b468200逐项一致。只更新本轮生产诊断文件指纹及报告/下一步，102行implementation/verification/acceptance不升级；20条唯一直接引用和旧全局证据定义保留，新报告链接旧报告。结构/阈值检查及15项台账回归通过，sourceMatches=true、releaseReady=false，require-ready退出1。

独立复审另有1项P3注释措辞待完善：源码`v7 sources: 0 not an error`可更精确写为“无已记录取消错误”。实际字段和本报告已正确限定source0包含发送失败，不影响行为或验收；按集中复审流程保留为deferred minor，随下次相关源码修改一并澄清。

[独立综合复审](evidence/2026-10-29-loopback-error-source/review-final.md)与[完整证据](evidence/2026-10-29-loopback-error-source/README.md)包含红灯及两平台最终矩阵、两轮完整媒体xcresult、原始失败、请求/策略/帧日志、来源制品绑定和历史核对。未推送、合并或发布。
'''
p.write_text(text)
l=Path('tool/release_readiness/inventory.json');d=json.loads(subprocess.check_output(['git','show','6b468200:'+str(l)]));d['source']=json.loads((r/'production-source.json').read_text());key='loopback-error-source-20261029';d['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in d['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[key if v=='budget-low-cause-20261029' else v for v in row['evidence']]
  row['nextAction']='isolate-player-side-high-request-reset-and-natural-retry-without-increasing-budget'
  assert len(row['evidence'])==len(set(row['evidence']))==20
l.write_text(json.dumps(d,indent=2)+'\n')
