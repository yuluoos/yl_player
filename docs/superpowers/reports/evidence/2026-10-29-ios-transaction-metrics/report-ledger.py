from pathlib import Path
import sys,json,hashlib
sys.path.insert(0,'tool/release_readiness');import check
root=Path.cwd();p=Path('tool/release_readiness/inventory.json');ledger=json.loads(p.read_text());snapshot=check.source_snapshot(root)
report=Path('docs/superpowers/reports/2026-10-29-ios-transaction-metrics.md')
report.write_text('''# iOS URLSession 事务指标与长素材复测

基线9a307e9c，分支codex/abr-recovery，承接[请求边界排查](2026-10-29-ios-request-timing.md)。集中验收；不推送、合并或发布。工程诊断实现及合约验证完成，ABR整体验收仍未完成。

## 实现与修复

在原有DEBUG显式request capture中增加URLSessionTaskMetrics，采样版本2。按任务保存总时长、事务数、重定向数和最多32条事务；按事务保存fetch、fetch→request、DNS、连接、TLS、请求发送、响应等待、响应接收时长，以及复用/协议/来源数字枚举。无URL、IP、凭据、任意头或原始协议字符串。缺失、逆序、非有限Date差保持null；实测零与缺失区分。仅同一Foundation Date时钟内取差，不与设备uptime或服务器绝对时刻相减。

沿用锁、一次封存、observer完成及drain所有权；取消可早于metrics回调，已封存的记录不接受迟到更新，缺失明确保留。默认无observer及Release均不启用这套trace。成功v2请求必须具备完整网络事务核心分段、正确分段总和、无截断；取消缺失不能冒充完整。缓存/未知来源不能计为完整网络事务。v1历史读取仍支持，探针与sidecar版本必须一致，混合/降级拒绝。

独立复审发现P2：任务总时长小于事务时长、重定向数大于事务数仍可通过。补充约束及红绿回归：fetchSeconds不得超过taskSeconds+1微秒，redirectCount不得大于transactionCount；取消后可能尚未产生下一事务，因此不强制再加1。定向复审关闭，无新增P1/P2。

初版macOS矩阵222通过、1失败：成功路径测试的URLSession客户端读满Content-Length后提前关闭，可能先于上游完成回调，按当前规则记录取消。保留该失败；测试改为NWConnection持续读取至代理EOF，仍要求成功终态、字节、metrics和边界顺序。生产取消/封存逻辑不改，不把合法取消改记为成功。真实请求红灯、日期缺失/非法合约、指标解析红绿及修正后定向测试均归档。

## 同一最终制品的两轮真机结果

用户授权继续保持前台后，在同一iPhone、同一最终制品完成两轮120秒采集。二进制哈希一致，输入414份指纹匹配，服务器收尾完成。两轮native XCTest均退出0；严格回执均失败，不能把native退出码当作ABR通过。没有后台、音频切换或host failure。

| 场景 | 严格结果 | EOF秒 / 宽度 | 自动安装 | 恢复后高档 | item边界新帧空档 / 全程最大空档 |
| --- | --- | --- | --- | --- | --- |
| 原配置down-and-recover-v1 | 失败，未恢复高档 | 120.030025 / 320 | 0 | 无 | 无替换 / 352.111ms |
| 既有恢复控制 | 失败，请求关联不完整 | 120.020139 / 640 | 1 | 65.971秒 | 314.087ms / 346.445ms |

原配置334条代理记录（333完成、1取消）全部关联；333条成功记录均有完整事务指标。9个完整窗口带宽0.359–0.840Mbps，全部低于固定0.955Mbps门槛，预约/票据/尝试均0。不能称为自动恢复修复。

恢复控制374条记录（366完成、8取消），366条成功事务完整；服务器媒体请求无遗漏，但1条代理取消未关联。该请求接入3.599ms后取消，body/发送次数均0，无response/upstreamComplete/metrics，随机关联ID未见于服务器请求日志。记录支持“响应前很早取消”，不足以证明请求完全未出设备、未到服务器或服务端没有漏记；这项仍未验收。保持原始receipt失败和原关联门槛，不补造服务器事件、不丢弃取消记录。

控制在约54.330秒完成一次安装，预算使用1，未观察到第二次安装。它沿用stall/headroom/zero-latency多变量诊断profile，只验证路径观察，不能证明原配置恢复已修复。此次替换帧空档314.087ms不优于上一轮156.339ms，不宣称连续性改善。物理输出、音画同步和整体连续性标志仍false。

## 原配置成本进一步定位

选择服务端25秒后、整请求位于恢复阶段且成功关联的239个请求，共3048374字节；同一集合分别测量：

| 区间 | 时长总和 |
| --- | ---: |
| 服务端处理/写出 | 20.583秒 |
| 代理接入至上游完成回调 | 42.008秒 |
| URLSession任务 | 41.933秒 |
| URLSession事务fetch | 41.793秒 |
| fetch至请求开始 | 12.041秒 |
| 其中连接 | 11.500秒 |
| 请求发送 | 0.023秒 |
| 请求结束至响应开始 | 18.531秒 |
| 响应接收 | 11.197秒 |
| 回环contentProcessed等待 | 0.395秒，单次最大1.677ms |

239个事务全部HTTP/1.x且连接复用0，DNS指标观测为0，TLS未提供（HTTP，不能记为测得零TLS耗时）。夹具network_profile.py明确HTTP/1.0、Connection: close且每请求关闭，与重复连接一致。连接11.500秒包含在fetch→request中，不能再相加；DNS/TLS等子区间也不能重复累计。URLSession任务与代理总区间仅差0.075秒，主要成本已包含在URLSession任务生命周期，现有数据不支持把全部差额归为代理完成回调迟到。

按相同请求集合计算代理区间有效吞吐约0.581Mbps、服务端约1.185Mbps，均为诊断量；并发区间总和不等于wall time或链路容量。连接成本是已观测贡献，响应等待仍包含网络与服务端延迟等，不能称为纯RTT。该证据尚不能证明启用keepalive或改生产连接策略即可恢复高档；本轮没有更改原夹具、扣除开销抬高带宽、强制高档或放宽门槛。

## 统一验收、归档和发布台账

最终macOS223/iPhone248用例通过，0失败0跳过，唯一用例集合与最终源码绑定；工具155通过，消费者45通过1项既有历史focused证据缺失跳过。当前/历史目标及源码镜像检查通过。原生编译警告保留，不宣称零警告。Dart/Pigeon/Android未改，历史执行不算本轮重跑。

414份最终输入冻结，初版原生输入另存；最终只有三份测试镜像与初版不同。初版失败、取消、不完整指标、完整xcresult、独立复审和全部原始receipt见[证据归档](evidence/2026-10-29-ios-transaction-metrics/README.md)。历史28组7097条清单与基线逐项保持一致。

生产源码快照哈希 `'''+snapshot['sha256']+'''`；唯一生产文件变化为YlHlsMediaProxy.swift中的DEBUG指标支持。恢复策略、955000bps、8秒双窗口、预算2、退避与候选期限不变。102行implementation/verification/acceptance状态保持；CAP-ABR/iOS仍partial/not_run。台账结构、15项回归及性能注册表检查通过，sourceMatches=true、releaseReady=false；两项--require-ready均退出1。

## 保留未完成项

- 原配置高档恢复：进一步做连接持久性单因素对照及真实生产服务器验证，保留当前每请求关闭的原配置作为独立基准；不能直接修改夹具追认本轮失败。
- 响应前快速取消的完整证据：需要可验证的任务终止/事务收尾与服务器接入边界，当前无法把这一条判为已完整关联，门槛不放宽。
- 多轮稳定性、更多生产网络/设备/最低系统、异步提交后故障及命令竞争仍未穷尽；真实重定向、缓存、多事务及取消晚到metrics的定向覆盖也未齐。
- 物理音画采集和设备/授权资源缺口继续保留，发布帧时间戳不代替真实屏幕和声音连续性。旧终末停顿不重新列为待办。

未发布。整体CAP-ABR仍不满足验收。
''')
key='ios-transaction-metrics-20261029';ledger['source']=snapshot;ledger['evidence'][key]=dict(path=str(report),sha256=hashlib.sha256(report.read_bytes()).hexdigest(),kind='report')
for row in ledger['rows']:
 if row['requirement']=='CAP-ABR' and row['platform']=='ios':
  if 'ios-request-timing-20261029' in row['evidence']:row['evidence'].remove('ios-request-timing-20261029')
  if key not in row['evidence']:row['evidence'].append(key)
  row['nextAction']='qualify-connection-persistence-original-high-recovery-pre-response-cancel-evidence-stability-physical-av'
p.write_text(json.dumps(ledger,indent=2)+'\n')
print('production source',snapshot['sha256'])
