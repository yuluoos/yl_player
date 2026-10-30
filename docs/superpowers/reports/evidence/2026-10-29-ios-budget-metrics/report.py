from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-budget-metrics');a=json.loads((r/'analysis.json').read_text());q=a['results']
p=Path('docs/superpowers/reports/2026-10-29-ios-budget-metrics.md')
text='''# iOS 双事务日期缺失与再次降档预算验收

基线7bfb3f55，承接[生产竞争原始失败](2026-10-29-ios-production-exercise.md)。本轮按系统排障、红绿测试与集中验收执行；保留原始失败，不放宽验收门槛，不发布。

## 已确认并修复的范围

在自有服务器首GET响应前关闭连接、第二GET正常返回4字节的实际Foundation实验中，URLSession自动产生2个事务、0重定向，最终请求成功；首事务缺少responseStartDate/responseEndDate，第二事务完整。新增原生回环测试在本轮iPhone及macOS均通过。它证明一个可复现诱因，不证明上一轮请求26的历史诱因就是连接关闭；原始失败仍是失败。Apple的[事务指标说明](https://developer.apple.com/documentation/foundation/urlsessiontasktransactionmetrics)允许未完成阶段没有结束日期，不能据此补造时间。

DEBUG代理采样升级到v3，嵌套URLSession指标v2增加8个区间的durationStates：0有效、1缺开始、2缺结束、3两端都缺、4无效/倒序日期。只记录有界分类，不输出绝对日期、URL、头或凭据。缺失时长继续为null；成功请求的所有事务核心区间仍须完整，不能丢弃第一次事务、补0或只选最后一次。生产恢复策略、媒体传输和重试行为未修改。原生日志分类与解析/带宽CLI支持新旧版本，新增反例保证v3成功请求含缺失事务时仍拒绝。

新增显式--require-budget-exhaustion，只允许生产恢复、要求实际安装、pause-resume或pause-prepared组合。必须第二次实际安装及凭据提交成功→安装后640帧→同item再次320帧且进度继续；所有策略记录绑定同一会话，安装后策略generation保持不变，意图与凭据版本绑定安装ticket。两个至少8秒的窗口各自满足3请求、进度、955000bps、缓冲5秒、剩余20秒、高档历史及overdue；仍需allowed且无pending票据。全部安装后记录预算为2，无第三预约/票据或额外事件。budgetExhaustionObservation独立于最终高档和连续性验收；不能用最终停留低档的轮次通过整个恢复验收。

独立综合复审发现三项P2：跨会话策略可能进入预算证据、权限变更后重开窗口可能掩盖变化、带宽CLI遗漏v3。真实红例复现后批量修复，针对性复审无新增P1/P2。全部红日志保留。

## 统一测试及制品身份

工具176/176通过；消费者46项中45通过、1项既有历史focused证据缺失跳过。规范源码清单为iOS876/macOS920；这是源码身份数量，不是本轮实际运行数量。本轮相关原生矩阵iPhone249/249、macOS224/224，0失败0跳过，按所选类的规范用例身份逐项绑定；其中新增双事务真实复现用例。原生定向红测1例失败（3个断言）、绿测3/3保留。首次macOS test-without-building因无xctestrun未启动测试的记录也保留，随后正常test执行。构建和运行警告保留。

436份源码/测试/工具输入采集前后相同，两轮307份iPhone制品指纹完全一致。Swift最终制品已重建；复审后仅Python验证器与测试修改，不需重建Swift。Dart/Android生产源码未变，本轮未重跑其全矩阵，不宣称新增这些平台的设备证据。

## 两轮真机预算与连续性证据

用户已确认准备后的10–15分钟前台窗口；两轮在iPhone16/iOS27.2完成，没有后台、音频切换信号或host failure。新诊断profile repeat-stall-budget-diagnostic-v1明确在旧首次停流profile上增加60–65秒再次停流：0秒500000B/s+40ms；10秒0B/s+40ms；15秒2000000B/s+0ms；60秒0B/s+0ms；65秒恢复2000000B/s+0ms。120秒素材，close模式。原配置文件及门槛未改；不同profile不能证明原配置不升档已修复。

两轮均从实际生产预约进入，第一预约因公开暂停作废但不退款；恢复播放后按第二次1000ms退避安装。500/1000ms退避、2次每源预算、准备2秒、票据5秒和原高档终态门槛全部不变。

| 场景 | 二次安装/再次低档(秒) | 两个窗口请求数及Mbps | 替换新帧间隔ms | 全程最大新帧间隔ms | EOF位置/最终宽度 | 预算证据/严格回执 |
| --- | --- | --- | --- | --- | --- | --- |
'''
for n,v in q.items():
 b=v['budget'];c=v['continuity'];f=v['final'];w=b['qualifiedCounterfactualWindows'];gap=c['replacementBoundaries'][0]['publicationGapMs']
 text+=f'| {n} | {b["secondInstallElapsed"]:.3f}/{b["secondDownshiftElapsed"]:.3f} | '+', '.join(f'{x["requests"]}/{x["bitrate"]/1e6:.3f}' for x in w)+f' | {gap:.3f} | {c["maximumPublishedFrameGapMs"]:.3f} | {f["position"]:.6f}/{f["width"]} | 通过/失败 |\n'
text+='''
预算专项2/2通过，原生探针2/2退出0、均到EOF；严格恢复回执0/2通过，独立重算亦保留两轮最终高档失败。两个8秒窗口分别为pause-resume 68.766–76.767–84.771秒、pause-prepared 68.509–76.759–84.759秒。第二次安装后维持同会话/权限和预算2，重新出现高档后再次低档，具备原门槛的反事实恢复条件，但没有第三预约，证明预算约束真实生效。不能为让该轮再次升高而返还取消预算或增加第三次预算。

两轮代理386/387条完全关联；成功事务完整，新v3带宽CLI实际执行成功。本轮自然长素材未再出现双事务，不能用这两轮未复现来关闭历史缺失项。分类3只说明对应阶段未采集，不等同错误时长；完整性仍按原核心区间判断。

替换处121.434/137.561ms是发布层相邻item新帧间隔，本轮没有修改替换实现，不能据两次样本宣称整体延迟改进。全程最大2057.321/2083.559ms包含测试主动暂停，应与替换边界分开保留。两轮纹理清空0、无无帧generation；候选后暂停首发布延迟53.024ms。没有校准的物理屏幕及音频采集，所以continuityAccepted、physicalOutputVerified、audioSynchronizationVerified、capabilityAccepted仍全部false。

## 归档、台账及未完成项

[完整证据](evidence/2026-10-29-ios-budget-metrics/README.md)保留原始日志、所有收据/帧/策略/边界/日期分类、红绿、构建、6个完整xcresult（定向红/绿、iOS/macOS矩阵、两轮媒体）、命令、复审、源码/制品身份。历史33组7739条哈希逐项核对，未覆盖任何历史失败。原始两轮passed=false原样保留。

生产源码指纹仅因DEBUG诊断所在Swift文件变化，由83c8ad3f…更新为62f46a45…；台账绑定新指纹，102行implementation/verification/acceptance状态不提升，旧evidence条目保留。CAP-ABR/iOS最近引用指向本报告，保持20引用限制与历史链路。发布台账结构、15项回归、性能注册表及diff检查通过；sourceMatches=true、releaseReady=false，两项--require-ready仍按预期退出1。不发布、不推送、不合并。

仍未完成：历史双事务缺失的原始诱因及重复稳定性闭合；原配置/真实生产网络下高档恢复稳定性，以及预算耗尽后停留低档的恢复能力边界；更多提交后故障/生命周期竞争和历史快速取消关联；物理画面/音画同步、更多设备和最低系统、授权媒体等资源缺口。旧终末停顿待办按用户要求不再恢复。本轮仅补齐明确诊断profile下的再次降档预算专项，不升级整体ABR或连续性验收。
'''
p.write_text(text)
ledger=Path('tool/release_readiness/inventory.json');d=json.loads(ledger.read_text());key='ios-budget-metrics-20261029';d['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report');d['source']=json.loads((r/'production-source.json').read_text())
for row in d['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  row['evidence']=[e for e in row['evidence'] if e!='ios-production-exercise-20261029']
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-historical-partial-transactions-original-stability-post-budget-high-recovery-fast-cancel-and-physical-av'
ledger.write_text(json.dumps(d,indent=2)+'\n')
plan=Path('docs/superpowers/plans/2026-10-29-budget-metrics.md');plan.write_text(plan.read_text().replace('- [ ]','- [x]')+'\n本批实施及统一验证完成：工具176；消费者45通过1既有跳过；iPhone249/macOS224；再次降档预算2/2，严格媒体0/2（最终低档），保持失败及物理音画缺口。完整记录见2026-10-29-ios-budget-metrics报告，不发布。\n')
