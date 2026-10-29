from pathlib import Path
import json,hashlib
r=Path('/private/tmp/yl-connection-persistence');a=json.loads((r/'analysis.json').read_text());p=Path('docs/superpowers/reports/2026-10-29-ios-connection-persistence.md')
p.write_text('''# iOS 连接持久性单因素对照

基线ac482e57，承接[事务成本报告](2026-10-29-ios-transaction-metrics.md)及[主分支合并记录](2026-10-29-abr-main-merge.md)。本轮实现诊断工具并完成已授权的三轮真机采集，不修改生产播放器、不合并、不发布。

## 实现和严格校验

原默认close仍HTTP/1.0逐请求关闭。新增显式http11-close和http11-keepalive，后两种同为HTTP/1.1，只改变是否保持连接；带宽/延迟profile、120秒素材、播放器制品及恢复门槛一致。CLI、服务器请求日志和回执均明确connectionMode；连接序号及每连接请求序号不包含IP、URL、凭据或头内容。

仍最多8个处理连接、10000个接受连接与10000条请求记录，2秒不活动时限、120秒绝对连接寿命。持久连接每次请求单独占记录预算；传输失败强制关闭，客户端显式close得到尊重；关闭服务器时中断并排空处理线程。连接证据在收尾后读取，未知/混合模式、缺失、重复、跳号或倒序不通过。原代理请求关联和v2成功事务完整性门槛不变，未豁免响应前取消。

真实socket红绿验证了GET/HEAD/Range、同连接复用、HTTP/1.1 close不复用、客户端close和记录预算；缺失连接证据会追加明确错误，更新对应失败回执测试要求该错误而非忽略。独立复审发现P2：排序后校验会接受同连接[2,1]倒序。已改为按原日志顺序比较1,2,...，保留红绿并定向复审关闭，无剩余阻断。

## 制品与统一验证

432份本轮源码/工具输入冻结。播放器和测试代码未变，packages/yl_player_apple、packages/yl_player_media_core及example/ios范围相对c7fad9c2完全一致；307份原生制品文件哈希与上一轮相同。三轮均复用该制品，不宣称本轮重建或重跑macOS223/iPhone248整套原生合约。工具161、消费者46测试通过，当前目标与源码一致性检查通过。三轮真机XCTest为2通过、1失败；该失败完整保留。

用户确认约9分钟前台采集窗口，三轮无后台/音频切换信号。均使用down-and-recover-v1：初始500000B/s+40ms，10秒降至50000B/s+200ms，25秒恢复500000B/s+40ms。所有策略门槛、预算及退避不变。

| 模式 | 严格回执 / native | 结束位置秒 / 宽度 | 自动安装 | 恢复后高档秒 | 服务器请求 / 连接 / 复用请求 |
| --- | --- | --- | --- | --- | --- |
| 原默认close | 通过 / 0 | 120.025059 / 640 | 0 | 81.959 | 346 / 346 / 0 |
| http11-close | 失败 / 65 | 18.910742 / 320 | 0 | 无 | 105 / 105 / 0 |
| http11-keepalive | 通过 / 0 | 120.021445 / 640 | 0 | 79.958 | 347 / 38 / 309 |

原默认和keepalive均为AVPlayer自然升档，自动恢复尝试0、未触发预算/替换；不能当作自动恢复方案通过，不能覆盖此前原配置不升档失败。最大新帧发布空档分别1263.484ms和1270.386ms，无item替换，物理输出、音画同步及整体连续性仍false。

http11-close在约34.881秒出现host failure，CoreMedia记录-16830“Media file not received in 2s”，另有-12889/-15628；最后播放位置18.910742秒，采集持续到约140秒而未EOF。103条代理请求（87完成、16取消）全部关联，服务器90完成、15客户端I/O错误；成功请求事务指标完整。尾部无新帧120460.684ms，不能只引用已发布帧之间最大330.341ms来称连续。该轮作为本次新场景失败保留，不重启旧终末停顿待办。

## 连接成本与不能外推的结论

恢复阶段（服务器25秒后完整成功请求）原默认251条：连接观测251次、复用0，连接总时长6.446秒，上游生命周期41.555秒、服务器28.204秒。keepalive同阶段251条：新连接指标仅25次、复用226次，观测连接时长0.603秒，但上游生命周期76.393秒、服务器59.618秒；不同选档/资源和顺序运行的环境变化使这些总和不能直接归因为连接策略。保持连接真实减少建连，但本轮整体请求区间并未随之改善。

为减少素材差异，另选两种HTTP/1.1模式均在25秒后完整成功、每轮唯一的相同asset/range/bytes请求，只剩7对，共117733字节。关闭模式上游1.376秒、服务器0.871秒；复用模式上游1.070秒、服务器0.807秒。前者7个连接指标合计0.246秒，后者7次均复用、连接指标全部缺失，保存为null而不是测得零。这个样本受关闭模式提前失败及仅成功请求选择影响，不能证明总体吞吐、稳定性或升档改善。

本轮已验证“诊断模式实际产生连接复用”，尚未证明“连接复用修复原配置ABR”。不更改原fixture默认，不启用生产复用补丁，不从带宽中扣除耗时，不降低955000bps、双8秒窗口或连续性门槛。

## 原始证据与台账

完整命令、红绿、复审、三轮原始回执/策略/帧/访问日志/事务指标、完整xcresult及哈希见[归档](evidence/2026-10-29-ios-connection-persistence/README.md)。旧失败及历史清单保持原样。新回执2/3通过只代表本轮诊断条件，并非CAP-ABR或发布通过。

生产源码指纹保持83c8ad3fe1693f53b58ff238ccee7d24615eea80c80cc5f59b3f65595e8c7bb3；102行implementation/verification/acceptance不提升。台账结构与15项回归、性能注册表校验通过；sourceMatches=true、releaseReady=false，两项--require-ready均退出1。旧证据entry全部保留，新报告承接上一轮直接引用以满足单行20引用上限。

仍未完成：原配置恢复的重复稳定性及真实服务器验证；HTTP/1.1关闭模式本轮超时归因，需要进一步区分共享整形等待、写出与接收成本；快速取消的原始未关联记录未被修复（本轮无自动替换，不能用干净关联追认）；生产竞争、更多设备/最低系统及物理音画、授权资源缺口继续保留。当前证据不支持增加新的生产恢复行为。
''')
ledger=Path('tool/release_readiness/inventory.json');x=json.loads(ledger.read_text());key='ios-connection-persistence-20261029';x['evidence'][key]=dict(path=str(p),sha256=hashlib.sha256(p.read_bytes()).hexdigest(),kind='report')
for row in x['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  if 'ios-transaction-metrics-20261029' in row['evidence']:row['evidence'].remove('ios-transaction-metrics-20261029')
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-server-wait-write-cost-original-recovery-fast-cancel-stability-and-physical-av'
ledger.write_text(json.dumps(x,indent=2)+'\n')
plan=Path('docs/superpowers/plans/2026-10-29-ios-connection-persistence.md');plan.write_text(plan.read_text().replace('- [ ]','- [x]')+'\n本轮结果：工具161/消费者46通过；同制品三轮严格诊断回执2通过1失败，自动尝试均0。原默认和保持连接自然升档但均有约1.27秒发布帧空档；HTTP/1.1关闭连接超时失败保留。实际复用已证实，生产ABR与连续性未通过，不合并、不发布。\n')
