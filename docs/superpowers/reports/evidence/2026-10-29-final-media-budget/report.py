from pathlib import Path
import json,hashlib,subprocess
r=Path('/private/tmp/yl-final-media-budget');a=json.loads((r/'analysis.json').read_text());b=json.loads((r/'byte-analysis.json').read_text());assert a['totalRuns']==3
p=Path('docs/superpowers/reports/2026-10-29-final-media-budget.md')
s='''# 新制品长素材高档恢复、预算耗尽与连续性验收

基线e951fce5，承接[原生超时溢出修复](2026-10-29-native-timeout-overflow.md)。用户授权准备后约9–12分钟前台采集；保留原始失败和设备/授权缺口，不放宽验收门槛，不发布。

## 制品与测试范围

438份源码/测试/工具输入和307份iPhone制品逐项与原生超时修复轮一致；使用该轮已通过iPhone254/254、macOS229/229选定矩阵的同一签名制品，未重复构建，未把选定矩阵冒充全部881/925注册用例。本轮新增三轮iPhone16/iOS27.2的120秒实机媒体采集；生产代码、阈值、解析器和自动恢复策略未修改。

normal使用repeat-stall-budget-diagnostic-v1，在10–15秒和60–65秒停流，恢复带宽2000000B/s；pause-resume使用相同profile，加公开暂停/恢复使首次预约作废且不退款，要求第二次实际安装后再次降档、反事实窗口达标且无第三预约。original沿用down-and-recover-v1原配置。三轮均close连接模式、manifest-only准备；参数/媒体/网络profile和完整命令绑定在原始证据中。

双8秒窗口、每窗至少3请求、955000bps、缓冲5秒、剩余20秒、每源预算2次、500/1000ms退避、准备2秒和票据5秒全部不变。预算专项通过不代表最终高档或连续性验收通过；不会因预算耗尽而退款或增加第三次预约。

## 三轮真机结果

| 场景 | 预算次数/实际安装 | EOF位置/最终宽度 | 替换新帧间隔ms | 最大新帧间隔ms | 严格/重算 |
| --- | --- | --- | --- | --- | --- |
'''
for n,v in a['results'].items():
 f=v['final'];g='/'.join(f'{x["publicationGapMs"]:.3f}' for x in v['continuity']['replacementBoundaries']) or '无替换'
 s+=f'| {n} | {f["automaticAttempts"]}/{sum(e["outcome"]=="installed" for e in f["automaticEvents"])} | {f["position"]:.6f}/{f["width"]} | {g} | {v["continuity"]["maximumPublishedFrameGapMs"]:.3f} | '+('通过' if v['receiptPassed'] else '失败')+'/'+('通过' if v['reassessmentPassed'] else '失败')+' |\n'
s+=f'\n严格回执{a["strictPasses"]}/3通过，独立重算{a["reassessedPasses"]}/3通过。三轮原生均退出0；采集CLI依次退出0/1/0。全部结果按原始回执保留，不把原生退出0、到EOF或单项预算成功替代严格验收。\n'
for n,v in a['results'].items():
 s+=f'\n### {n}\n\n原始错误：'+json.dumps(v['receiptErrors'],ensure_ascii=False)+'；独立重算错误：'+json.dumps(v['errors'],ensure_ascii=False)+'。\n'
 if v['secondInstallProof']:
  q=v['secondInstallProof'];s+=f'首轮高档{q["firstHigh"]:.3f}秒，再低档{q["secondLow"]:.3f}秒，第二次安装{q["secondInstall"]:.3f}秒，新generation高档{q["secondHigh"]:.3f}秒，高档尾部{q["highTailSeconds"]:.3f}秒，尾部始终高档={q["stableHighTail"]}。\n'
 if v['budget']:
  q=v['budget'];s+=f'预算专项通过：第二次安装{q["secondInstallElapsed"]:.3f}秒，安装后再次低档{q["secondDownshiftElapsed"]:.3f}秒；两窗口为'+json.dumps(q['qualifiedCounterfactualWindows'],ensure_ascii=False)+'。安装后权限、会话和generation绑定不变，预算始终2且没有第三次预约；不能据此声称预算耗尽后自然高档已恢复。\n'
 if n=='original':s+='原配置结果独立列出；没有实际安装时只证明该轮自然播放/恢复，不能算作生产替换验证。\n'
 z=b[n];s+=f'代理{z["proxyCount"]}条，取消{z["cancelled"]}、发送失败{z["sendFailed"]}（原始终态保留），缺metrics {z["missingMetrics"]}、空事务{z["zeroTransactionMetrics"]}、双事务{z["multiTransactions"]}、未关联{z["uncorrelated"]}。信号记录='+json.dumps(v['signals'],ensure_ascii=False)+'。\n'
s+='''
替换间隔来自发布层真实新帧采样，最大间隔包含测试主动暂停；两者分开记录。纹理保留、generation和位置证据按原算法核对，不将其包装为物理屏幕/音频同步通过。缺少校准物理音画采集，continuityAccepted、physicalOutputVerified和capabilityAccepted仍false。不凭跨轮间隔差异宣称性能改进。

## 历史双事务核查

历史六轮原始字节诊断重算仍3通过/3失败。C459CA68-0CFA-4FC2-BA04-9A3359F8E0F2/request4的首事务有请求日期、缺响应日期，0重定向、两事务均reused=0，服务器只解析一个关联请求；旧metrics v2没有字节计数，不能补成0。

从本制品上一轮两平台已通过的受控原生用例提取完整附件（明确为复用证据，未计新执行）：自有服务器解析首请求后主动关闭连接，第二次请求成功。iOS首/次事务各记录313个请求头字节，macOS各316；首事务响应头/体0/0，次事务84/4，服务器同trace ID解析两次。它证明“已解析后关闭”可产生双事务缺响应，且无法用请求时长代替响应证据；与历史只有一次解析及缺字节计数的条件不同，仍不能确定历史重试原因。不丢弃首事务、不填补缺失日期，成功事务完整性门槛保持原状。

## 集中验收、保留项与台账

网络工具200/200、消费者45通过/1既有历史focused证据跳过、注册来源与881/925用例身份检查通过。沿用同制品原生矩阵的438份输入与307份制品绑定，未声称本轮新跑两平台矩阵。原始运行警告及诊断采集警告完整保留。46组9845条历史证据哈希与基线一致，所有原始失败和旧报告不改。

仍保留严格失败（如上）、跨轮高档恢复稳定性、预算耗尽后的自然恢复、更多提交后故障/生命周期竞争、历史双事务内部原因、历史macOS就绪超时，以及更多设备/最低系统/实际网络/授权素材和物理音画缺口。旧终末停顿待办不重新加入。

生成脚本重复运行曾追加重复引用，导致台账结构退出2；原始失败和修复前脚本保留。修复为从固定基线派生最近引用，新增幂等回归先失败后通过，并重跑台账检查。20条引用上限不变，旧报告由新报告首段继续链接，旧全局证据定义不删。

台账生产指纹不变；102行implementation/verification/acceptance不升级，只更新最近证据引用与下一步，旧证据定义保留。结构/阈值和15项台账回归通过，sourceMatches=true、releaseReady=false，require-ready仍退出1。独立综合复审见[复审记录](evidence/2026-10-29-final-media-budget/review-final.md)。

[完整原始证据](evidence/2026-10-29-final-media-budget/README.md)含三轮完整xcresult、请求/事务/帧/策略/信号原始输出、失败与回执、制品绑定、复用证据来源及复审。未推送、合并或发布。
'''
p.write_text(s)
l=Path('tool/release_readiness/inventory.json');d=json.loads(l.read_text());assert d['source']==json.loads((r/'production-source.json').read_text());key='final-media-budget-20261029';d['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in d['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  baseline=json.loads(subprocess.check_output(['git','show','e951fce5:tool/release_readiness/inventory.json']))
  previous=next(x for x in baseline['rows'] if x['requirement']=='CAP-ABR' and x['platform']=='ios')
  row['evidence']=[v for v in previous['evidence'] if v!='native-timeout-overflow-20261029']+[key]
  row['nextAction']='qualify-exhausted-budget-natural-recovery-continuity-and-historical-dual-transactions'
l.write_text(json.dumps(d,indent=2)+'\n')
